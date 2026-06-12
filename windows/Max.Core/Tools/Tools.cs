using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>The result of running a tool: text content, error flag, and any images.</summary>
public sealed record ToolOutcome(string Content, bool IsError, IReadOnlyList<ImagePayload> Images)
{
    public static ToolOutcome Ok(string content) => new(content, false, Array.Empty<ImagePayload>());
    public static ToolOutcome Fail(string content) => new(content, true, Array.Empty<ImagePayload>());
    public static ToolOutcome WithImage(string content, ImagePayload image) => new(content, false, new[] { image });
}

/// <summary>A capability Max can invoke. The Windows head adds screen/UIA/app-control tools.</summary>
public interface IMaxTool
{
    ToolSpec Spec { get; }
    string Summary(JsonObject input);
    Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct);
}

public sealed class ToolRegistry
{
    private readonly Dictionary<string, IMaxTool> _tools;
    public ToolRegistry(IEnumerable<IMaxTool> tools) =>
        _tools = tools.ToDictionary(t => t.Spec.Name, t => t);

    public IReadOnlyList<ToolSpec> Specs => _tools.Values.Select(t => t.Spec).ToList();
    public IMaxTool? Get(string name) => _tools.TryGetValue(name, out var t) ? t : null;
}

/// <summary>Run a shell command. Cross-platform: PowerShell on Windows, /bin/sh elsewhere.</summary>
public sealed class ExecTool : IMaxTool
{
    private readonly MaxConfig _config;
    public ExecTool(MaxConfig config) => _config = config;

    public ToolSpec Spec => new(
        "exec",
        "Run a shell command on the user's PC and return its output. On Windows this is PowerShell. " +
        "Use for launching apps, file operations, scripting, system queries — anything a terminal can do.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["command"] = new JsonObject { ["type"] = "string", ["description"] = "The command line to run." },
            },
            ["required"] = new JsonArray("command"),
        });

    public string Summary(JsonObject input) => $"run: {(string?)input["command"] ?? ""}";

    public async Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct)
    {
        var command = (string?)input["command"] ?? "";
        if (string.IsNullOrWhiteSpace(command)) return ToolOutcome.Fail("no command provided");

        var blocked = CommandGuard.Block(command, _config);
        if (blocked != null) return ToolOutcome.Fail(blocked);

        return await RunShellAsync(command, TimeSpan.FromSeconds(120), ct);
    }

    public static async Task<ToolOutcome> RunShellAsync(string command, TimeSpan timeout, CancellationToken ct)
    {
        var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
        var psi = isWindows
            ? new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -Command -")
            : new ProcessStartInfo("/bin/sh", "-s");
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;

        using var proc = new Process { StartInfo = psi };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        proc.OutputDataReceived += (_, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
        proc.ErrorDataReceived += (_, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };

        try
        {
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            await proc.StandardInput.WriteAsync(command);
            proc.StandardInput.Close();

            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            try { await proc.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException)
            {
                try { proc.Kill(true); } catch { }
                return ToolOutcome.Fail($"command timed out after {timeout.TotalSeconds:0}s");
            }
        }
        catch (Exception ex)
        {
            return ToolOutcome.Fail($"failed to launch shell: {ex.Message}");
        }

        var output = stdout.ToString().TrimEnd();
        var err = stderr.ToString().TrimEnd();
        var combined = err.Length > 0 ? $"{output}\n[stderr]\n{err}".Trim() : output;
        if (combined.Length > 40_000) combined = combined[..40_000] + "\n…[truncated]";
        var failed = proc.ExitCode != 0;
        return new ToolOutcome(
            combined.Length == 0 ? (failed ? $"(exit {proc.ExitCode}, no output)" : "(no output)") : combined,
            failed, Array.Empty<ImagePayload>());
    }
}

public sealed class ReadFileTool : IMaxTool
{
    public ToolSpec Spec => new(
        "read_file",
        "Read a UTF-8 text file from disk and return its contents.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject { ["path"] = new JsonObject { ["type"] = "string" } },
            ["required"] = new JsonArray("path"),
        });

    public string Summary(JsonObject input) => $"read {(string?)input["path"] ?? ""}";

    public Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct)
    {
        var path = (string?)input["path"] ?? "";
        try
        {
            if (!File.Exists(path)) return Task.FromResult(ToolOutcome.Fail($"no file at {path}"));
            var text = File.ReadAllText(path);
            if (text.Length > 60_000) text = text[..60_000] + "\n…[truncated]";
            return Task.FromResult(ToolOutcome.Ok(text));
        }
        catch (Exception ex) { return Task.FromResult(ToolOutcome.Fail(ex.Message)); }
    }
}

public sealed class WriteFileTool : IMaxTool
{
    public ToolSpec Spec => new(
        "write_file",
        "Write (or overwrite) a UTF-8 text file on disk.",
        new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["path"] = new JsonObject { ["type"] = "string" },
                ["content"] = new JsonObject { ["type"] = "string" },
            },
            ["required"] = new JsonArray("path", "content"),
        });

    public string Summary(JsonObject input) => $"write {(string?)input["path"] ?? ""}";

    public Task<ToolOutcome> ExecuteAsync(JsonObject input, CancellationToken ct)
    {
        var path = (string?)input["path"] ?? "";
        var content = (string?)input["content"] ?? "";
        try
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(path, content);
            return Task.FromResult(ToolOutcome.Ok($"wrote {content.Length} chars to {path}"));
        }
        catch (Exception ex) { return Task.FromResult(ToolOutcome.Fail(ex.Message)); }
    }
}
