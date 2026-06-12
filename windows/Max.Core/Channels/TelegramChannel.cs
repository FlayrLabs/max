using System.Text;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>
/// Telegram bot channel — long-poll getUpdates, reply with sendMessage. Allowlist is
/// the user's NUMERIC id (from @userinfobot), never the bot's username.
/// </summary>
public sealed class TelegramChannel
{
    private readonly ISecretStore _secrets;
    private readonly ChannelRouter _router;
    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private CancellationTokenSource? _cts;
    private long _offset;

    public TelegramChannel(ISecretStore secrets, ChannelRouter router) { _secrets = secrets; _router = router; }

    public void Start()
    {
        var config = MaxConfig.Load();
        var token = _secrets.Get("telegram-bot");
        if (!config.TelegramEnabled || string.IsNullOrEmpty(token)) return;
        if (_cts != null) return;
        _cts = new CancellationTokenSource();
        _ = PollLoopAsync(token!, _cts.Token);
    }

    public void Stop() { _cts?.Cancel(); _cts = null; }

    private async Task PollLoopAsync(string token, CancellationToken ct)
    {
        await PrimeOffsetAsync(token, ct);
        ChannelLog.Write("telegram: connected, polling");
        while (!ct.IsCancellationRequested)
        {
            var updates = await GetUpdatesAsync(token, 30, ct);
            if (updates is null) { try { await Task.Delay(3000, ct); } catch { } continue; }
            foreach (var u in updates)
            {
                if ((long?)u?["update_id"] is long id) _offset = Math.Max(_offset, id + 1);
                await HandleAsync(u!.AsObject(), token, ct);
            }
        }
    }

    private async Task PrimeOffsetAsync(string token, CancellationToken ct)
    {
        var updates = await GetUpdatesAsync(token, 0, ct);
        if (updates is null) return;
        foreach (var u in updates)
            if ((long?)u?["update_id"] is long id) _offset = Math.Max(_offset, id + 1);
    }

    private async Task<JsonArray?> GetUpdatesAsync(string token, int timeout, CancellationToken ct)
    {
        try
        {
            var url = $"https://api.telegram.org/bot{token}/getUpdates?offset={_offset}&timeout={timeout}";
            using var resp = await Http.GetAsync(url, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);
            var obj = JsonNode.Parse(body)?.AsObject();
            if (obj?["ok"]?.GetValue<bool>() != true)
            {
                ChannelLog.Write($"telegram: API error {obj?["description"]} — check the bot token");
                return null;
            }
            return obj!["result"] as JsonArray ?? new JsonArray();
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex) { ChannelLog.Write($"telegram: poll error {ex.Message}"); return null; }
    }

    private async Task HandleAsync(JsonObject update, string token, CancellationToken ct)
    {
        var message = update["message"]?.AsObject();
        var text = (string?)message?["text"];
        var from = message?["from"]?.AsObject();
        var chat = message?["chat"]?.AsObject();
        if (message is null || string.IsNullOrWhiteSpace(text) || from is null || chat is null) return;
        if (from["is_bot"]?.GetValue<bool>() == true) return;

        var userId = ((long?)from["id"])?.ToString() ?? "0";
        var chatId = ((long?)chat["id"])?.ToString() ?? "0";
        if (userId == "0" || chatId == "0") return;

        var allow = MaxConfig.Load().TelegramAllowlist;
        if (!allow.Contains(userId))
        {
            ChannelLog.Write($"telegram: ignored message from {(string?)from["username"] ?? "?"} (id {userId}) — not in allowlist");
            return;
        }

        ChannelLog.Write($"telegram: handling message from {userId}");
        await _router.HandleAsync($"telegram-{chatId}", text!.Trim(),
            reply => SendMessageAsync(chatId, reply, token), ct);
    }

    private static async Task SendMessageAsync(string chatId, string text, string token)
    {
        try
        {
            var body = new JsonObject { ["chat_id"] = chatId, ["text"] = text.Length > 4000 ? text[..4000] : text };
            using var content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            await Http.PostAsync($"https://api.telegram.org/bot{token}/sendMessage", content);
        }
        catch (Exception ex) { ChannelLog.Write($"telegram: send error {ex.Message}"); }
    }
}
