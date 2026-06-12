using System.Text.Json;
using System.Text.RegularExpressions;

namespace Max.Core;

/// <summary>
/// Blocks dangerous commands before they run — the safety net for headless
/// (loop/channel) runs that can't pop an approval dialog. Mirrors the macOS
/// CommandGuard: builtin patterns + the user's denylist.
/// </summary>
public static class CommandGuard
{
    // Windows-flavored destructive patterns (plus a few cross-platform ones).
    private static readonly string[] BuiltinPatterns =
    {
        @"rmdir\s+/s\s+/q\s+[a-zA-Z]:\\?$",   // wipe a drive root
        @"\bformat\s+[a-zA-Z]:",               // format a volume
        @"\bdel\s+/s\s+/q\s+[a-zA-Z]:\\",      // recursive delete from root
        @"\brm\s+-rf\s+/",                      // unix-style, in case of WSL/git-bash
        @"Remove-Item.+-Recurse.+-Force.+[a-zA-Z]:\\\s*$",
        @"\bdiskpart\b",
        @"\bcipher\s+/w",                       // secure-wipe free space
        @"vssadmin\s+delete\s+shadows",         // ransomware hallmark
        @"\bbcdedit\b.*\bdelete\b",
        @":\(\)\s*\{.*\};:",                    // fork bomb
        @"\bshutdown\b\s+/r?\s*/?f",            // forced shutdown/restart
    };

    public static string? Block(string command, MaxConfig config)
    {
        if (config.UseDefaultDenylist)
            foreach (var p in BuiltinPatterns)
                if (Regex.IsMatch(command, p, RegexOptions.IgnoreCase))
                    return $"Blocked by built-in safety rule ({p}).";

        foreach (var raw in config.CommandDenylist)
        {
            var pat = raw.Trim();
            if (pat.Length == 0) continue;
            try
            {
                if (Regex.IsMatch(command, pat, RegexOptions.IgnoreCase))
                    return $"Blocked by your denylist rule ({pat}).";
            }
            catch (ArgumentException)
            {
                // Not valid regex — treat as a literal substring.
                if (command.Contains(pat, StringComparison.OrdinalIgnoreCase))
                    return $"Blocked by your denylist rule ({pat}).";
            }
        }
        return null;
    }
}

/// <summary>Per-model token pricing → a daily USD cap recorded in spend.json.</summary>
public static class SpendTracker
{
    // USD per 1M tokens (input, output). Matches the macOS pricing table.
    private static readonly Dictionary<string, (double In, double Out)> Pricing = new(StringComparer.OrdinalIgnoreCase)
    {
        ["claude-fable-5"] = (10.0, 50.0),
        ["claude-opus-4-8"] = (5.0, 25.0),
        ["claude-opus-4-7"] = (5.0, 25.0),
        ["claude-opus-4-6"] = (5.0, 25.0),
        ["claude-sonnet-4-6"] = (3.0, 15.0),
        ["claude-haiku-4-5"] = (1.0, 5.0),
        ["gpt-4o"] = (2.5, 10.0),
        ["gpt-4o-mini"] = (0.15, 0.6),
    };

    private static readonly object Gate = new();

    private static string Today => DateTime.UtcNow.ToString("yyyy-MM-dd");

    public static void Record(string model, int inputTokens, int outputTokens)
    {
        if (!Pricing.TryGetValue(model, out var price)) price = (5.0, 25.0); // sensible default
        var cost = inputTokens / 1_000_000.0 * price.In + outputTokens / 1_000_000.0 * price.Out;
        lock (Gate)
        {
            var data = ReadAll();
            data.TryGetValue(Today, out var spent);
            data[Today] = spent + cost;
            File.WriteAllText(MaxPaths.SpendFile, JsonSerializer.Serialize(data));
        }
    }

    public static double SpentToday()
    {
        lock (Gate)
        {
            ReadAll().TryGetValue(Today, out var v);
            return v;
        }
    }

    public static bool IsOverLimit(MaxConfig config) =>
        config.DailySpendLimitUSD > 0 && SpentToday() >= config.DailySpendLimitUSD;

    private static Dictionary<string, double> ReadAll()
    {
        try
        {
            if (File.Exists(MaxPaths.SpendFile))
                return JsonSerializer.Deserialize<Dictionary<string, double>>(File.ReadAllText(MaxPaths.SpendFile)) ?? new();
        }
        catch { }
        return new();
    }
}

/// <summary>Append-only audit log of every tool action.</summary>
public static class ActionLog
{
    private static readonly object Gate = new();

    public static void Write(string line)
    {
        try
        {
            MaxPaths.Ensure();
            lock (Gate)
                File.AppendAllText(MaxPaths.ActionsLog, $"[{DateTime.UtcNow:O}] {line}{Environment.NewLine}");
        }
        catch { }
    }
}
