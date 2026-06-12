import Foundation

/// Runs a shell command on one of the user's OTHER Macs over SSH — the
/// multi-device control surface (mirrors OpenClaw's `nodes` tool). Devices are
/// configured in Settings → Devices; passwordless key-based SSH should be set
/// up to each (LAN or Tailscale).
struct RemoteExecTool: MaxTool {
    let devices: [RemoteDevice]

    var spec: ToolSpec {
        let list = devices.map { d -> String in
            let what = d.note.isEmpty ? d.host : d.note
            return "\(d.name) (\(what))"
        }.joined(separator: ", ")
        return ToolSpec(
            name: "remote_exec",
            description: """
            Run a shell command on one of the user's OTHER Macs over SSH. Use to \
            check on or act on a different machine than this one. Available devices: \
            \(list.isEmpty ? "none configured" : list). Returns the remote stdout+stderr.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "device": [
                        "type": "string",
                        "description": "Which device to run on (one of the configured names)",
                        "enum": devices.map(\.name),
                    ],
                    "command": ["type": "string", "description": "The shell command to run on that device"],
                    "timeout_seconds": ["type": "integer", "description": "Max seconds to wait (default 60, max 600)"],
                ],
                "required": ["device", "command"],
            ]
        )
    }

    func summary(input: [String: Any]) -> String {
        let device = input["device"] as? String ?? "?"
        let command = input["command"] as? String ?? ""
        return "\(device) $ \(command.prefix(100))"
    }

    func execute(input: [String: Any]) async -> ToolOutcome {
        guard let deviceName = input["device"] as? String,
              let command = input["command"] as? String, !command.isEmpty else {
            return .fail("remote_exec requires `device` and `command`")
        }
        if let blocked = CommandGuard.block(command) { return blocked }
        // Re-read config so newly added/edited devices are picked up.
        guard let device = MaxConfig.load().devices.first(where: { $0.name == deviceName }) else {
            return .fail("No device named '\(deviceName)'. Configure it in Settings → Devices.")
        }
        let timeout = min(max(input["timeout_seconds"] as? Int ?? 60, 1), 600)

        var ssh = "ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
        if device.port != 22 { ssh += " -p \(device.port)" }
        if !device.identityFile.isEmpty {
            let key = (device.identityFile as NSString).expandingTildeInPath
            ssh += " -i '\(key)'"
        }
        ssh += " \(device.user)@\(device.host)"

        // The remote command is passed as a single single-quoted argument.
        let remote = command.replacingOccurrences(of: "'", with: "'\\''")
        let full = "\(ssh) '\(remote)'"

        let outcome = await ExecTool.runShell(full, timeout: timeout)
        if outcome.isError, outcome.content.contains("Could not resolve")
            || outcome.content.contains("Connection refused")
            || outcome.content.contains("Operation timed out")
            || outcome.content.contains("Permission denied") {
            return .fail("Couldn't reach \(deviceName) (\(device.user)@\(device.host)). " +
                "Check it's online and passwordless SSH is set up.\n\(outcome.content)")
        }
        return outcome
    }
}
