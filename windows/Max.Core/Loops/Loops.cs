using System.Text.Json;
using System.Text.Json.Serialization;

namespace Max.Core;

public enum LoopSchedule { Every, Daily, Once }

/// <summary>A scheduled autonomous agent run.</summary>
public sealed class LoopDef
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N")[..8];
    public string Name { get; set; } = "";
    public string Prompt { get; set; } = "";
    public LoopSchedule Schedule { get; set; } = LoopSchedule.Every;
    public int IntervalMinutes { get; set; } = 60;  // Every
    public string Time { get; set; } = "09:00";     // Daily (local HH:mm)
    public DateTime? AtUtc { get; set; }            // Once
    public bool Enabled { get; set; } = true;
    public DateTime? LastRunUtc { get; set; }
}

public static class LoopStore
{
    private static readonly object Gate = new();
    private static string Path => System.IO.Path.Combine(MaxPaths.Root, "loops.json");
    private static readonly JsonSerializerOptions Opts = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static List<LoopDef> Load()
    {
        lock (Gate)
        {
            try
            {
                if (File.Exists(Path))
                    return JsonSerializer.Deserialize<List<LoopDef>>(File.ReadAllText(Path), Opts) ?? new();
            }
            catch { }
            return new();
        }
    }

    public static void Save(List<LoopDef> loops)
    {
        lock (Gate)
        {
            MaxPaths.Ensure();
            File.WriteAllText(Path, JsonSerializer.Serialize(loops, Opts));
        }
    }

    public static void Upsert(LoopDef loop)
    {
        var all = Load();
        var i = all.FindIndex(l => l.Id == loop.Id);
        if (i >= 0) all[i] = loop; else all.Add(loop);
        Save(all);
    }

    public static void Delete(string id)
    {
        var all = Load();
        all.RemoveAll(l => l.Id == id);
        Save(all);
    }
}

/// <summary>
/// Ticks once a minute and runs any due loop through the agent (isLoopRun=true).
/// Mirrors the macOS LoopScheduler: every / daily / once, isolated sessions,
/// NO_REPLY convention, results surfaced via the injected notifier (a Windows toast).
/// </summary>
public sealed class LoopScheduler
{
    private readonly ISecretStore _secrets;
    private readonly Func<MaxConfig, IReadOnlyList<IMaxTool>> _toolsFactory;
    private readonly Action<string, string>? _notify;
    private readonly SemaphoreSlim _runGate = new(1, 1);
    private Timer? _timer;

    public LoopScheduler(ISecretStore secrets, Func<MaxConfig, IReadOnlyList<IMaxTool>> toolsFactory, Action<string, string>? notify = null)
    {
        _secrets = secrets;
        _toolsFactory = toolsFactory;
        _notify = notify;
    }

    public void Start() => _timer ??= new Timer(_ => _ = TickAsync(), null, TimeSpan.Zero, TimeSpan.FromSeconds(60));

    public void Stop() { _timer?.Dispose(); _timer = null; }

    private async Task TickAsync()
    {
        if (MaxConfig.Load().Paused) return;
        foreach (var loop in LoopStore.Load())
        {
            if (!loop.Enabled || !IsDue(loop, DateTime.UtcNow)) continue;
            await RunAsync(loop);
        }
    }

    public static bool IsDue(LoopDef loop, DateTime nowUtc)
    {
        switch (loop.Schedule)
        {
            case LoopSchedule.Every:
                return loop.LastRunUtc is null || nowUtc - loop.LastRunUtc >= TimeSpan.FromMinutes(Math.Max(1, loop.IntervalMinutes));
            case LoopSchedule.Daily:
                if (!TimeOnly.TryParse(loop.Time, out var t)) t = new TimeOnly(9, 0);
                var nowLocal = nowUtc.ToLocalTime();
                var ranToday = loop.LastRunUtc?.ToLocalTime().Date == nowLocal.Date;
                return !ranToday && nowLocal.TimeOfDay >= t.ToTimeSpan();
            case LoopSchedule.Once:
                return loop.AtUtc != null && nowUtc >= loop.AtUtc && loop.LastRunUtc is null;
            default:
                return false;
        }
    }

    private async Task RunAsync(LoopDef loop)
    {
        await _runGate.WaitAsync();
        try
        {
            var config = MaxConfig.Load();
            var session = new ChatSession($"loop-{loop.Id}");
            var tools = _toolsFactory(config);
            var final = "";
            await foreach (var ev in AgentLoop.RunAsync(
                session, loop.Prompt, config, _secrets, tools,
                approval: null, isLoopRun: true, isRemoteOrigin: false))
            {
                if (ev is AgentEvent.TurnEnded te) final = te.FinalText;
            }

            loop.LastRunUtc = DateTime.UtcNow;
            if (loop.Schedule == LoopSchedule.Once) loop.Enabled = false;
            LoopStore.Upsert(loop);

            final = final.Trim();
            if (final.Length > 0 && !final.Equals("NO_REPLY", StringComparison.OrdinalIgnoreCase))
                _notify?.Invoke(loop.Name.Length > 0 ? loop.Name : "Max loop", final);
            ActionLog.Write($"loop '{loop.Name}' ran ({(final.Length == 0 ? "no output" : "reported")})");
        }
        catch (Exception ex) { ActionLog.Write($"loop '{loop.Name}' error: {ex.Message}"); }
        finally { _runGate.Release(); }
    }
}
