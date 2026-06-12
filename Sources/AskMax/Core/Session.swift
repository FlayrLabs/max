import Foundation

/// Append-only JSONL transcript, OpenClaw-style. One file per session under
/// ~/.askmax/sessions/. The main chat uses a single persistent session;
/// loop runs get isolated sessions.
final class ChatSession {
    let id: String
    private(set) var turns: [ChatTurn] = []
    private let fileURL: URL

    init(id: String) {
        self.id = id
        MaxPaths.ensure()
        self.fileURL = MaxPaths.sessionsDir.appendingPathComponent("\(id).jsonl")
        loadFromDisk()
    }

    static func main() -> ChatSession { ChatSession(id: "main") }

    static func isolated(prefix: String) -> ChatSession {
        ChatSession(id: "\(prefix)-\(UUID().uuidString.prefix(8))")
    }

    var isEmpty: Bool { turns.isEmpty }

    func append(_ turn: ChatTurn) {
        turns.append(turn)
        guard let data = try? JSONEncoder().encode(turn),
              let line = String(data: data, encoding: .utf8) else { return }
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func clear() {
        turns = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadFromDisk() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            if let turn = try? decoder.decode(ChatTurn.self, from: Data(line.utf8)) {
                turns.append(turn)
            }
        }
    }
}

// MARK: - Conversation index (one .jsonl per conversation; loop-* files excluded)

struct ConversationMeta: Identifiable, Equatable {
    let id: String
    let title: String
    let modifiedAt: Date
}

enum Conversations {
    static func newId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "chat-\(formatter.string(from: Date()))"
    }

    static func mostRecentId() -> String? { list().first?.id }

    static func list() -> [ConversationMeta] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: MaxPaths.sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var metas: [ConversationMeta] = []
        for url in files where url.pathExtension == "jsonl" {
            let id = url.deletingPathExtension().lastPathComponent
            if id.hasPrefix("loop-") { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? nil
            metas.append(ConversationMeta(
                id: id,
                title: title(for: url) ?? id,
                modifiedAt: modified ?? .distantPast
            ))
        }
        return metas.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func delete(id: String) {
        let url = MaxPaths.sessionsDir.appendingPathComponent("\(id).jsonl")
        try? FileManager.default.removeItem(at: url)
    }

    /// First user text in the transcript, trimmed — used as the display title.
    private static func title(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 16_384),
              let head = String(data: data, encoding: .utf8) else { return nil }
        try? handle.close()
        let decoder = JSONDecoder()
        for line in head.split(separator: "\n") {
            guard let turn = try? decoder.decode(ChatTurn.self, from: Data(line.utf8)),
                  turn.role == .user else { continue }
            for case .text(let t) in turn.blocks {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed.count > 46 ? String(trimmed.prefix(46)) + "…" : trimmed
                }
            }
        }
        return nil
    }
}

// MARK: - System prompt

enum SystemPrompt {
    static func build(config: MaxConfig, soul: String, isLoopRun: Bool, includeVision: Bool = false) -> String {
        let host = Host.current().localizedName ?? "this Mac"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d yyyy, HH:mm zzz"
        let now = formatter.string(from: Date())
        let user = config.userName.isEmpty ? "the user" : config.userName

        var prompt = """
        You are Max, the personal Mac assistant inside the AskMax app. You belong to \(user) \
        and you have hands-on access to their Mac through your tools.

        ## Machine
        - Computer: \(host), macOS \(osVersion)
        - Home directory: \(home)
        - Current time: \(now)

        ## Operating rules
        - You control this Mac via `exec` (shell) and `applescript`. Prefer doing things over describing them.
        - Use `read_file`/`write_file` for files, `exec` for everything else the system can do.
        - When \(user) asks for something recurring ("every morning", "every hour", "keep an eye on"), \
        use the `loop` tool to schedule it instead of saying you can't.
        - Keep replies tight: what you found, what you did, what's left. This renders in a small chat window.
        - Plain text only — no markdown tables, minimal headers.\(includeVision ? """

        - You can SEE the screen: `read_screen_text` for text content (cheap, private), \
        `see_screen` for an actual screenshot when layout/visuals matter. When \(config.userName.isEmpty ? "the user" : config.userName) \
        says "this", "here", or asks about what they're looking at — look first, then answer.
        """ : "")

        ## Soul (instructions from \(user))
        \(soul)
        """

        if !config.devices.isEmpty {
            let lines = config.devices.map { d -> String in
                let what = d.note.isEmpty ? "" : " — \(d.note)"
                return "- \(d.name): \(d.user)@\(d.host)\(what)"
            }.joined(separator: "\n")
            prompt += """


            ## Other Macs you can control
            \(user) has these other machines. Use the `remote_exec` tool (device = the name) to \
            run commands on them over SSH. "This Mac" is \(host); the rest are remote:
            \(lines)
            """
        }

        if isLoopRun {
            prompt += """


            ## Loop run
            This is an automated, scheduled run — \(user) is not watching. Do the task, then end with \
            one short summary line of the outcome. If there is genuinely nothing worth telling \(user) \
            (nothing changed, nothing needs attention), end your reply with exactly: NO_REPLY
            """
        }
        return prompt
    }
}
