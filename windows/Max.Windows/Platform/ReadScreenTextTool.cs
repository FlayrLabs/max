using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using System.Text.Json.Nodes;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using Max.Core;

namespace Max.Windows.Platform;

/// <summary>
/// read_screen_text — read the focused window's text via UI Automation (no pixels), the
/// Windows analog of the macOS AXUIElement reader. Cheaper and more private than a
/// screenshot when the words matter more than the visuals.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ReadScreenTextTool : IMaxTool
{
    public ToolSpec Spec => new(
        "read_screen_text",
        "Read the text of the focused window via UI Automation — no screenshot, nothing leaves the PC. " +
        "Use for articles, dialogs, code, chats: anything where the words matter more than the visuals.",
        new JsonObject { ["type"] = "object", ["properties"] = new JsonObject(), ["required"] = new JsonArray() });

    public string Summary(JsonObject input) => "reading the front window";

    public Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct) => Task.Run(() =>
    {
        try
        {
            var hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return ToolOutcome.Fail("no foreground window");

            using var automation = new UIA3Automation();
            var element = automation.FromHandle(hwnd);
            if (element is null) return ToolOutcome.Fail("could not access the foreground window");

            var title = SafeName(element);
            var seen = new HashSet<string>();
            var sb = new StringBuilder();
            var budget = 1200;

            void Walk(AutomationElement el, int depth)
            {
                if (depth > 24 || budget <= 0) return;
                budget--;

                var name = SafeName(el);
                if (name.Length is > 1 and < 8000 && seen.Add(name)) sb.AppendLine(name);
                if (TryValue(el, out var val) && val.Length is > 1 and < 8000 && seen.Add(val)) sb.AppendLine(val);

                AutomationElement[] children;
                try { children = el.FindAllChildren(); } catch { return; }
                foreach (var c in children.Take(80)) Walk(c, depth + 1);
            }

            Walk(element, 0);

            var text = sb.ToString().Trim();
            if (text.Length == 0) return ToolOutcome.Fail("that window exposes no readable text via UI Automation — try see_screen.");
            if (text.Length > 40_000) text = text[..40_000] + "\n…[truncated]";
            return ToolOutcome.Ok($"Window: {title}\n---\n{text}");
        }
        catch (Exception ex) { return ToolOutcome.Fail($"UI Automation failed: {ex.Message}"); }
    }, ct);

    private static string SafeName(AutomationElement el)
    {
        try { return el.Name ?? ""; } catch { return ""; }
    }

    private static bool TryValue(AutomationElement el, out string value)
    {
        value = "";
        try
        {
            if (el.Patterns.Value.IsSupported)
            {
                value = el.Patterns.Value.Pattern.Value ?? "";
                return value.Length > 0;
            }
        }
        catch { }
        return false;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
}
