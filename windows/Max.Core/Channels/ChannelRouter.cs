namespace Max.Core;

/// <summary>Append-only diagnostics for channels (ignored senders, connect/handle events).</summary>
public static class ChannelLog
{
    private static readonly object Gate = new();
    public static string Path => System.IO.Path.Combine(MaxPaths.Root, "channels.log");

    public static void Write(string line)
    {
        try
        {
            MaxPaths.Ensure();
            lock (Gate)
                File.AppendAllText(Path, $"[{DateTime.UtcNow:O}] {line}{Environment.NewLine}");
        }
        catch { }
    }
}

/// <summary>
/// Routes an inbound channel message (iMessage/Telegram/Discord/Slack) through the
/// agent and hands the reply back. Each channel conversation gets its own persistent
/// ChatSession ("chan-&lt;key&gt;") and is serialized so messages don't interleave.
/// Headless: runs with isRemoteOrigin=true (auto-approval; denylist is the safety net).
/// </summary>
public sealed class ChannelRouter
{
    private readonly ISecretStore _secrets;
    private readonly Func<MaxConfig, IReadOnlyList<IMaxTool>> _toolsFactory;
    private readonly object _gate = new();
    private readonly Dictionary<string, SemaphoreSlim> _locks = new();
    private readonly Dictionary<string, ChatSession> _sessions = new();

    public ChannelRouter(ISecretStore secrets, Func<MaxConfig, IReadOnlyList<IMaxTool>> toolsFactory)
    {
        _secrets = secrets;
        _toolsFactory = toolsFactory;
    }

    public async Task HandleAsync(string key, string text, Func<string, Task> reply, CancellationToken ct = default)
    {
        var sem = GetLock(key);
        await sem.WaitAsync(ct);
        try
        {
            var session = GetSession(key);
            var config = MaxConfig.Load();
            var tools = _toolsFactory(config);

            var final = "";
            await foreach (var ev in AgentLoop.RunAsync(
                session, text, config, _secrets, tools,
                approval: null, isLoopRun: false, isRemoteOrigin: true, images: null, ct: ct))
            {
                if (ev is AgentEvent.TurnEnded te) final = te.FinalText;
                else if (ev is AgentEvent.Failed f) final = "⚠ " + f.Message;
            }

            final = final.Trim();
            if (final.Length > 0 && !final.Equals("NO_REPLY", StringComparison.OrdinalIgnoreCase))
                await reply(final);
        }
        catch (Exception ex) { ChannelLog.Write($"router error on {key}: {ex.Message}"); }
        finally { sem.Release(); }
    }

    private SemaphoreSlim GetLock(string key)
    {
        lock (_gate)
        {
            if (!_locks.TryGetValue(key, out var s)) { s = new SemaphoreSlim(1, 1); _locks[key] = s; }
            return s;
        }
    }

    private ChatSession GetSession(string key)
    {
        lock (_gate)
        {
            if (!_sessions.TryGetValue(key, out var s)) { s = new ChatSession($"chan-{key}"); _sessions[key] = s; }
            return s;
        }
    }
}
