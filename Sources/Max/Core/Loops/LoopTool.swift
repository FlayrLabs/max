import Foundation

/// The agent-facing scheduling tool — OpenClaw's `cron` tool, simplified.
/// Lets the user say "check X every hour" and have Max wire it up itself.
struct LoopTool: MaxTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "loop",
            description: """
            Manage recurring loops — autonomous scheduled runs of Max. Use when the user wants \
            something done repeatedly or later ("every morning", "every 30 minutes", "tonight at 9"). \
            Each run executes `prompt` as a fresh Max session with full tool access; results are \
            delivered as macOS notifications and stored in the Loops panel. \
            Actions: add (name, prompt, and one of every_minutes / daily_at / once_at), \
            list, remove (name), run_now (name).
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["add", "list", "remove", "run_now"],
                    ],
                    "name": ["type": "string", "description": "Short loop name, e.g. 'morning-brief'"],
                    "prompt": ["type": "string", "description": "What Max should do on each run"],
                    "every_minutes": ["type": "integer", "description": "Run every N minutes"],
                    "daily_at": ["type": "string", "description": "Run daily at HH:mm (24h), e.g. '08:30'"],
                    "once_at": ["type": "string", "description": "Run once at ISO-8601 time, e.g. '2026-06-12T21:00:00Z'"],
                ],
                "required": ["action"],
            ]
        )
    }

    func summary(input: [String: Any]) -> String {
        let action = input["action"] as? String ?? "?"
        let name = input["name"] as? String ?? ""
        return "loop \(action) \(name)".trimmingCharacters(in: .whitespaces)
    }

    func execute(input: [String: Any]) async -> ToolOutcome {
        let action = input["action"] as? String ?? ""
        switch action {
        case "add": return await add(input)
        case "list": return await list()
        case "remove": return await remove(input)
        case "run_now": return await runNow(input)
        default: return .fail("unknown action '\(action)'")
        }
    }

    private func parseSchedule(_ input: [String: Any]) -> LoopSchedule? {
        if let minutes = input["every_minutes"] as? Int, minutes >= 1 {
            return .everyMinutes(minutes)
        }
        if let daily = input["daily_at"] as? String {
            let parts = daily.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) {
                return .dailyAt(hour: parts[0], minute: parts[1])
            }
        }
        if let once = input["once_at"] as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: once) { return .once(date) }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: once) { return .once(date) }
        }
        return nil
    }

    private func add(_ input: [String: Any]) async -> ToolOutcome {
        guard let name = input["name"] as? String, !name.isEmpty,
              let prompt = input["prompt"] as? String, !prompt.isEmpty else {
            return .fail("add requires `name` and `prompt`")
        }
        guard let schedule = parseSchedule(input) else {
            return .fail("add requires one of every_minutes, daily_at (HH:mm) or once_at (ISO-8601)")
        }
        let loop = MaxLoop(name: name, prompt: prompt, schedule: schedule)
        await MainActor.run {
            LoopStore.shared.remove(id: name) // replace same-named loop
            LoopStore.shared.add(loop)
        }
        return .ok("Loop '\(name)' scheduled — \(schedule.displayName).")
    }

    private func list() async -> ToolOutcome {
        let loops = await MainActor.run { LoopStore.shared.loops }
        if loops.isEmpty { return .ok("No loops scheduled.") }
        let lines = loops.map { loop in
            let status = loop.enabled ? "on" : "off"
            let last = loop.lastSummary.map { " | last: \($0.prefix(80))" } ?? ""
            return "- \(loop.name) [\(status)] \(loop.schedule.displayName): \(loop.prompt.prefix(80))\(last)"
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private func remove(_ input: [String: Any]) async -> ToolOutcome {
        guard let name = input["name"] as? String, !name.isEmpty else {
            return .fail("remove requires `name`")
        }
        let existed = await MainActor.run { () -> Bool in
            let had = LoopStore.shared.loops.contains { $0.name == name || $0.id == name }
            LoopStore.shared.remove(id: name)
            return had
        }
        return existed ? .ok("Loop '\(name)' removed.") : .fail("No loop named '\(name)'.")
    }

    private func runNow(_ input: [String: Any]) async -> ToolOutcome {
        guard let name = input["name"] as? String,
              let loop = await MainActor.run(body: { LoopStore.shared.loops.first { $0.name == name || $0.id == name } })
        else { return .fail("No loop with that name.") }
        await MainActor.run { LoopScheduler.shared.runNow(loop) }
        return .ok("Loop '\(loop.name)' kicked off in the background.")
    }
}
