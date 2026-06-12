using System.Runtime.Versioning;
using System.Text.Json.Nodes;
using Max.Core;

namespace Max.Windows.Platform;

/// <summary>
/// control_app — launch apps, focus windows, and type into them, the Windows analog of
/// the macOS AppleScript tool. Implemented with PowerShell + WScript.Shell (AppActivate
/// / SendKeys). Guarded by the same CommandGuard denylist as exec.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class AppControlTool : IMaxTool
{
    private readonly MaxConfig _config;
    public AppControlTool(MaxConfig config) => _config = config;

    public ToolSpec Spec => new(
        "control_app",
        "Control a Windows application. action=open launches an app (by name like 'notepad' or a path); " +
        "action=focus brings a window to the front by its title; action=type focuses a window by title then " +
        "types text into it (SendKeys syntax — e.g. {ENTER}, ^c for Ctrl+C).",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["action"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("open", "focus", "type") },
                ["app"] = new JsonObject { ["type"] = "string", ["description"] = "app name or path (for open)" },
                ["title"] = new JsonObject { ["type"] = "string", ["description"] = "window title substring (for focus/type)" },
                ["text"] = new JsonObject { ["type"] = "string", ["description"] = "text/keys to send (for type)" },
            },
            ["required"] = new JsonArray("action"),
        });

    public string Summary(JsonObject input) =>
        $"control_app {(string?)input["action"]}: {(string?)input["app"] ?? (string?)input["title"] ?? ""}";

    public async Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct)
    {
        var action = (string?)input["action"] ?? "";
        var command = action switch
        {
            "open" => $"Start-Process {PSQuote((string?)input["app"] ?? "")}",
            "focus" => $"$w = New-Object -ComObject WScript.Shell; $null = $w.AppActivate({PSQuote((string?)input["title"] ?? "")})",
            "type" =>
                $"$w = New-Object -ComObject WScript.Shell; $null = $w.AppActivate({PSQuote((string?)input["title"] ?? "")}); " +
                $"Start-Sleep -Milliseconds 250; $w.SendKeys({PSQuote((string?)input["text"] ?? "")})",
            _ => "",
        };
        if (command.Length == 0) return ToolOutcome.Fail($"unknown action '{action}'");

        var blocked = CommandGuard.Block(command, _config);
        if (blocked != null) return ToolOutcome.Fail(blocked);

        var outcome = await ExecTool.RunShellAsync(command, TimeSpan.FromSeconds(30), ct);
        return outcome.IsError ? outcome : ToolOutcome.Ok($"ok: {Summary(input)}");
    }

    private static string PSQuote(string s) => "'" + s.Replace("'", "''") + "'";
}
