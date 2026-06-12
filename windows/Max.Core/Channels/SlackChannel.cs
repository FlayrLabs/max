using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>
/// Slack channel over Socket Mode: apps.connections.open → WebSocket → events_api
/// envelopes, replying with chat.postMessage. Needs an app-level token (xapp-, with
/// connections:write) and a bot token (xoxb-). Allowlist = your Slack member ID (U…).
/// </summary>
public sealed class SlackChannel
{
    private static readonly HttpClient Http = new();
    private readonly ISecretStore _secrets;
    private readonly ChannelRouter _router;
    private CancellationTokenSource? _cts;

    public SlackChannel(ISecretStore secrets, ChannelRouter router) { _secrets = secrets; _router = router; }

    public void Start()
    {
        var config = MaxConfig.Load();
        var appToken = _secrets.Get("slack-app");
        var botToken = _secrets.Get("slack-bot");
        if (!config.SlackEnabled || string.IsNullOrEmpty(appToken) || string.IsNullOrEmpty(botToken)) return;
        if (_cts != null) return;
        _cts = new CancellationTokenSource();
        _ = RunAsync(appToken!, botToken!, _cts.Token);
    }

    public void Stop() { _cts?.Cancel(); _cts = null; }

    private async Task RunAsync(string appToken, string botToken, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await ConnectOnceAsync(appToken, botToken, ct); }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { ChannelLog.Write($"slack: {ex.Message}"); }
            try { await Task.Delay(5000, ct); } catch { return; }
        }
    }

    private async Task ConnectOnceAsync(string appToken, string botToken, CancellationToken ct)
    {
        var wssUrl = await OpenConnectionAsync(appToken, ct);
        if (wssUrl is null) { try { await Task.Delay(10000, ct); } catch { } return; }

        using var ws = new ClientWebSocket();
        await ws.ConnectAsync(new Uri(wssUrl), ct);
        ChannelLog.Write("slack: connected (socket mode)");

        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            var raw = await ReceiveAsync(ws, ct);
            if (raw is null) break;
            JsonObject msg;
            try { msg = JsonNode.Parse(raw)!.AsObject(); } catch { continue; }

            var type = (string?)msg["type"];
            if (type == "disconnect") break;
            if (type != "events_api") continue;

            // Acknowledge the envelope immediately.
            if ((string?)msg["envelope_id"] is string envId)
            {
                var ackBytes = Encoding.UTF8.GetBytes(new JsonObject { ["envelope_id"] = envId }.ToJsonString());
                await ws.SendAsync(ackBytes, WebSocketMessageType.Text, true, ct);
            }

            var ev = msg["payload"]?["event"]?.AsObject();
            if (ev is null || (string?)ev["type"] != "message") continue;
            if (ev["bot_id"] != null || ev["subtype"] != null) continue; // skip bots/edits/joins

            var userId = (string?)ev["user"] ?? "";
            var text = (string?)ev["text"] ?? "";
            var channel = (string?)ev["channel"] ?? "";
            if (string.IsNullOrWhiteSpace(text) || channel.Length == 0) continue;

            var allow = MaxConfig.Load().SlackAllowlist;
            if (!allow.Contains(userId))
            {
                ChannelLog.Write($"slack: ignored message from {userId} — not in allowlist");
                continue;
            }

            ChannelLog.Write($"slack: handling message from {userId}");
            await _router.HandleAsync($"slack-{channel}", text.Trim(),
                reply => PostMessageAsync(channel, reply, botToken), ct);
        }
    }

    private static async Task<string?> OpenConnectionAsync(string appToken, CancellationToken ct)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, "https://slack.com/api/apps.connections.open");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", appToken);
            using var resp = await Http.SendAsync(req, ct);
            var obj = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct))?.AsObject();
            if (obj?["ok"]?.GetValue<bool>() == true) return (string?)obj["url"];
            ChannelLog.Write($"slack: connections.open error {obj?["error"]}");
            return null;
        }
        catch (Exception ex) { ChannelLog.Write($"slack: open error {ex.Message}"); return null; }
    }

    private static async Task PostMessageAsync(string channel, string text, string botToken)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, "https://slack.com/api/chat.postMessage");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", botToken);
            var body = new JsonObject { ["channel"] = channel, ["text"] = text };
            req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            await Http.SendAsync(req);
        }
        catch (Exception ex) { ChannelLog.Write($"slack: send error {ex.Message}"); }
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
