using System.Text;

namespace Max.Core;

/// <summary>Builds Max's system prompt from config + the user's soul.md.</summary>
public static class SystemPrompt
{
    public static string Build(MaxConfig config, bool isLoopRun, bool includeVision)
    {
        var sb = new StringBuilder();
        var name = string.IsNullOrWhiteSpace(config.UserName) ? "the user" : config.UserName;

        sb.AppendLine($"You are Max, a native assistant living on {name}'s Windows PC. You don't just chat — you operate the computer to get things done.");
        sb.AppendLine();
        sb.AppendLine("Capabilities:");
        sb.AppendLine("- exec: run PowerShell to launch apps, manage files, query the system, script anything.");
        sb.AppendLine("- read_file / write_file: read and write text files on disk.");
        if (includeVision)
            sb.AppendLine("- see_screen / read_screen_text: look at what's on screen (screenshot) or read the focused window's text via UI Automation.");
        sb.AppendLine();
        sb.AppendLine("Operating principles:");
        sb.AppendLine("- Be decisive and act. Prefer doing the task over describing how.");
        sb.AppendLine("- Chain tools: inspect, act, verify. Keep going until the goal is met or you're truly blocked.");
        sb.AppendLine("- Be concise in replies; the user is busy.");
        sb.AppendLine("- Never run destructive commands without being explicit about what they do.");

        var soul = LoadSoul();
        if (!string.IsNullOrWhiteSpace(soul))
        {
            sb.AppendLine();
            sb.AppendLine("The user's standing instructions (soul.md) — follow these:");
            sb.AppendLine(soul!.Trim());
        }

        if (isLoopRun)
        {
            sb.AppendLine();
            sb.AppendLine("This is an autonomous background run (a Loop). There is no human watching in real time. " +
                          "Do the work and finish. If there is genuinely nothing to report, reply with exactly NO_REPLY.");
        }

        return sb.ToString();
    }

    public static string? LoadSoul()
    {
        try { return File.Exists(MaxPaths.SoulFile) ? File.ReadAllText(MaxPaths.SoulFile) : null; }
        catch { return null; }
    }
}
