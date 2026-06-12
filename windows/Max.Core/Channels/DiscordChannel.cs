using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>
/// Discord bot channel over the Gateway WebSocket (HELLO → IDENTIFY → heartbeat →
/// MESSAGE_CREATE), replying via the REST API. Needs the MESSAGE CONTENT privileged
/// intent enabled in the Developer Portal. Allowlist = your numeric Discord user ID.
/// </summary>
public sealed class DiscordChannel
{
    private const int Intents = (1 << 9) | (1 << 12) | (1 << 15); // GUILD_MESSAGES | DIRECT_MESSAGES | MESSAGE_CONTENT
    private static readonly HttpClient Http = new();
    private readonly ISecretStore _secrets;
    private readonly ChannelRouter _router;
    private CancellationTokenSource? _cts;

    public DiscordChannel(ISecretStore secrets, ChannelRouter router) { _secrets = secrets; _router = router; }

    public void Start()
    {
        var config = MaxConfig.Load();
        var token = _secrets.Get("discord-bot");
        if (!config.DiscordEnabled || string.IsNullOrEmpty(token)) return;
        if (_cts != null) return;
        _cts = new CancellationTokenSource();
        _ = RunAsync(token!, _cts.Token);
    }

    public void Stop() { _cts?.Cancel(); _cts = null; }

    private async Task RunAsync(string token, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await ConnectOnceAsync(token, ct); }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { ChannelLog.Write($"discord: {ex.Message}"); }
            try { await Task.Delay(5000, ct); } catch { return; } // reconnect backoff
        }
    }

    private async Task ConnectOnceAsync(string token, CancellationToken ct)
    {
        using var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri("wss://gateway.discord.gg/?v=10&encoding=json"), ct);
        var sendLock = new SemaphoreSlim(1, 1);
        int? lastSeq = null;
        var heartbeatCts = CancellationTokenSource.CreateLinkedTokenSource(ct);

        async Task Send(JsonObject payload)
        {
            await sendLock.WaitAsync(ct);
            try
            {
                var bytes = Encoding.UTF8.GetBytes(payload.ToJsonString());
                await ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct);
            }
            finally { sendLock.Release(); }
        }

        ChannelLog.Write("discord: connected, awaiting hello");

        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            var raw = await ReceiveAsync(ws, ct);
            if (raw is null) break;
            JsonObject msg;
            try { msg = JsonNode.Parse(raw)!.AsObject(); } catch { continue; }

            var op = (int?)msg["op"] ?? -1;
            if (msg["s"] is JsonNode s && s.GetValueKind() == System.Text.Json.JsonValueKind.Number) lastSeq = (int)s;

            switch (op)
            {
                case 10: // HELLO
                    var interval = (int)msg["d"]!["heartbeat_interval"]!;
                    _ = HeartbeatLoop(Send, () => lastSeq, interval, heartbeatCts.Token);
                    await Send(new JsonObject
                    {
                        ["op"] = 2,
                        ["d"] = new JsonObject
                        {
                            ["token"] = token,
                            ["intents"] = Intents,
                            ["properties"] = new JsonObject { ["os"] = "windows", ["browser"] = "max", ["device"] = "max" },
                        },
                    });
                    break;

                case 0: // dispatch
                    if ((string?)msg["t"] == "MESSAGE_CREATE")
                        await HandleMessageAsync(msg["d"]!.AsObject(), token, ct);
                    break;

                case 7:  // reconnect requested
                case 9:  // invalid session
                    heartbeatCts.Cancel();
                    return;
            }
        }
        heartbeatCts.Cancel();
    }

    private static async Task HeartbeatLoop(Func<JsonObject, Task> send, Func<int?> seq, int intervalMs, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await Task.Delay(intervalMs, ct);
                await send(new JsonObject { ["op"] = 1, ["d"] = seq() is int n ? n : (JsonNode?)null });
            }
        }
        catch { }
    }

    private async Task HandleMessageAsync(JsonObject d, string token, CancellationToken ct)
    {
        var author = d["author"]?.AsObject();
        var content = (string?)d["content"];
        var channelId = (string?)d["channel_id"];
        if (author is null || string.IsNullOrWhiteSpace(content) || channelId is null) return;
        if (author["bot"]?.GetValue<bool>() == true) return;

        var userId = (string?)author["id"] ?? "";
        var allow = MaxConfig.Load().DiscordAllowlist;
        if (!allow.Contains(userId))
        {
            ChannelLog.Write($"discord: ignored message from {(string?)author["username"] ?? "?"} (id {userId}) — not in allowlist");
            return;
        }

        ChannelLog.Write($"discord: handling message from {userId}");
        await _router.HandleAsync($"discord-{channelId}", content!.Trim(),
            reply => SendMessageAsync(channelId, reply, token), ct);
    }

    private static async Task SendMessageAsync(string channelId, string text, string token)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, $"https://discord.com/api/v10/channels/{channelId}/messages");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bot", token);
            var body = new JsonObject { ["content"] = text.Length > 1900 ? text[..1900] : text };
            req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            await Http.SendAsync(req);
        }
        catch (Exception ex) { ChannelLog.Write($"discord: send error {ex.Message}"); }
    }

    private static async Task<string?> ReceiveAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        using var ms = new MemoryStream();
        WebSocketReceiveResult result;
        do
        {
            try { result = await ws.ReceiveAsync(buffer, ct); }
            catch { return null; }
            if (result.MessageType == WebSocketMessageType.Close) return null;
            ms.Write(buffer, 0, result.Count);
        } while (!result.EndOfMessage);
        return Encoding.UTF8.GetString(ms.ToArray());
    }
}
