import Foundation

/// A tool Max can call. Mirrors OpenClaw's descriptor-driven tool model:
/// JSON-Schema input, async execution, plain-text result.
protocol MaxTool {
    var spec: ToolSpec { get }
    /// One-line human summary of a call, shown in the chat ("$ ls ~/Desktop").
    func summary(input: [String: Any]) -> String
    func execute(input: [String: Any]) async -> ToolOutcome
}

struct ToolOutcome {
    let content: String
    let isError: Bool
    var images: [ImagePayload] = []

    static func ok(_ content: String) -> ToolOutcome { .init(content: content, isError: false) }
    static func fail(_ message: String) -> ToolOutcome { .init(content: message, isError: true) }
    static func image(_ caption: String, _ image: ImagePayload) -> ToolOutcome {
        .init(content: caption, isError: false, images: [image])
    }
}

final class ToolRegistry {
    private(set) var tools: [String: MaxTool] = [:]

    init(_ tools: [MaxTool]) {
        for tool in tools { self.tools[tool.spec.name] = tool }
    }

    var specs: [ToolSpec] { tools.values.map(\.spec).sorted { $0.name < $1.name } }

    func tool(named name: String) -> MaxTool? { tools[name] }
}

// MARK: - exec: run shell commands

struct ExecTool: MaxTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "exec",
            description: """
            Run a shell command on this Mac (zsh). Use for anything the system can do: \
            file operations, opening apps/URLs (`open`), system info, brew, git, networking, \
            defaults, osascript one-liners, etc. Returns stdout+stderr (truncated to 20KB). \
            Long-running daemons should be backgrounded with `&`.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command to run"],
                    "timeout_seconds": ["type": "integer", "description": "Max seconds to wait (default 60, max 600)"],
                ],
                "required": ["command"],
            ]
        )
    }

    func summary(input: [String: Any]) -> String {
        "$ \((input["command"] as? String ?? "").prefix(120))"
    }

    func execute(input: [String: Any]) async -> ToolOutcome {
        guard let command = input["command"] as? String, !command.isEmpty else {
            return .fail("missing `command`")
        }
        if let blocked = CommandGuard.block(command) { return blocked }
        let timeout = min(max(input["timeout_seconds"] as? Int ?? 60, 1), 600)
        return await Self.runShell(command, timeout: timeout)
    }

    static func runShell(_ command: String, timeout: Int) async -> ToolOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .fail("failed to launch: \(error.localizedDescription)"))
                    return
                }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: killer)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()

                var output = String(data: data, encoding: .utf8) ?? ""
                if output.count > 20_000 {
                    output = String(output.prefix(20_000)) + "\n…[truncated]"
                }
                if output.isEmpty { output = "(no output)" }
                let status = process.terminationStatus
                if status != 0 {
                    continuation.resume(returning: .fail("exit \(status)\n\(output)"))
                } else {
                    continuation.resume(returning: .ok(output))
                }
            }
        }
    }
}

// MARK: - applescript: drive macOS apps

struct AppleScriptTool: MaxTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "applescript",
            description: """
            Run AppleScript to control macOS apps and UI — send iMessages, control Music/Spotify, \
            read Safari tabs, create Calendar events/Reminders/Notes, show notifications \
            (`display notification`), adjust volume, etc.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "script": ["type": "string", "description": "The AppleScript source to run"],
                ],
                "required": ["script"],
            ]
        )
    }

    func summary(input: [String: Any]) -> String {
        "AppleScript: \((input["script"] as? String ?? "").prefix(100))"
    }

    func execute(input: [String: Any]) async -> ToolOutcome {
        guard let script = input["script"] as? String, !script.isEmpty else {
            return .fail("missing `script`")
        }
        if let blocked = CommandGuard.block(script) { return blocked }
        // osascript via shell keeps everything on one execution path.
        let escaped = script.replacingOccurrences(of: "'", with: "'\\''")
        let command = "osascript -e '\(escaped)'"

        var outcome = await ExecTool.runShell(command, timeout: 120)

        // First-time control of an app triggers a macOS Automation prompt and
        // the event fails with -1743 ("Not authorized to send Apple events")
        // until the user clicks Allow. Wait for the prompt to be answered, then
        // retry once so the first call succeeds instead of erroring.
        if outcome.isError, Self.isAuthorizationError(outcome.content) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            outcome = await ExecTool.runShell(command, timeout: 120)
            if outcome.isError, Self.isAuthorizationError(outcome.content) {
                return .fail(
                    "macOS hasn't granted Max permission to control this app yet. " +
                    "Approve the \"Max wants to control…\" prompt (or enable it in " +
                    "System Settings → Privacy & Security → Automation), then try again."
                )
            }
        }
        return outcome
    }

    private static func isAuthorizationError(_ text: String) -> Bool {
        text.contains("-1743") || text.contains("Not authorized to send Apple events")
    }
}

// MARK: - read_file / write_file

struct ReadFileTool: MaxTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "read_file",
            description: "Read a text file from disk. Returns up to 50KB.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path or ~-relative path"],
                ],
                "required": ["path"],
            ]
        )
    }

    func summary(input: [String: Any]) -> String {
        "read \(input["path"] as? String ?? "?")"
    }

    func execute(input: [String: Any]) async -> ToolOutcome {
        guard let raw = input["path"] as? String else { return .fail("missing `path`") }
        let path = (raw as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .fail("could not read \(path)")
        }
        return .ok(text.count > 50_000 ? String(text.prefix(50_000)) + "\n…[truncated]" : text)
    }
}

struct WriteFileTool: MaxTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "write_file",
            description: "Write a text file to disk (creates parent directories). Overwrites existing content.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path or ~-relative path"],
                    "content": ["type": "string", "description": "The full file content to write"],
                ],
                "required": ["path", "content"],
            ]
        )
    }

    func summary(input: [String: Any]) -> String {
        "write \(input["path"] as? String ?? "?")"
    }

    func execute(input: [String: Any]) async -> ToolOutcome {
        guard let raw = input["path"] as? String, let content = input["content"] as? String else {
            return .fail("missing `path` or `content`")
        }
        let path = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .ok("wrote \(content.count) chars to \(path)")
        } catch {
            return .fail("write failed: \(error.localizedDescription)")
        }
    }
}
