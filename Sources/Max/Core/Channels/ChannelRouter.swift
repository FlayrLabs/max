import Foundation

/// Routes inbound messages from external channels (Discord, Slack) through the
/// agent. Each conversation gets its own persistent session (so different
/// channels/DMs don't collide and continuity survives restarts), runs are
/// serialized per conversation, and tool approval is forced to auto since
/// nobody is at the Mac to click a dialog.
@MainActor
final class ChannelRouter {
    static let shared = ChannelRouter()

    private var sessions: [String: ChatSession] = [:]
    private var busy: Set<String> = []
    private var queues: [String: [(text: String, reply: (String) -> Void)]] = [:]

    private init() {}

    /// `key` uniquely identifies a conversation, e.g. "discord-<channelId>".
    func handle(key: String, text: String, reply: @escaping (String) -> Void) {
        queues[key, default: []].append((text, reply))
        pump(key)
    }

    private func pump(_ key: String) {
        guard !busy.contains(key) else { return }
        guard var queue = queues[key], !queue.isEmpty else { return }
        let item = queue.removeFirst()
        queues[key] = queue
        busy.insert(key)

        let session = sessions[key] ?? {
            let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let s = ChatSession(id: "chan-" + String(safe))
            sessions[key] = s
            return s
        }()

        let config = MaxConfig.load()

        Task { [weak self] in
            var finalText = ""
            for await event in AgentLoop.run(session: session, userText: item.text,
                                             config: config, isRemoteOrigin: true) {
                switch event {
                case .turnEnded(let t): finalText = t
                case .failed(let m): finalText = "⚠️ \(m)"
                default: break
                }
            }
            item.reply(finalText.isEmpty ? "Done." : finalText)
            self?.busy.remove(key)
            self?.pump(key)
        }
    }
}
