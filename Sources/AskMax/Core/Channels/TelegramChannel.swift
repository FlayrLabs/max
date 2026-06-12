import Foundation

/// Telegram bot — the simplest channel: long-poll getUpdates (no WebSocket, no
/// public webhook), reply with sendMessage. Token comes from @BotFather.
@MainActor
final class TelegramChannel {
    static let shared = TelegramChannel()

    private var running = false
    private var token = ""
    private var offset = 0
    private var pollTask: Task<Void, Never>?

    private init() {}

    func startIfEnabled() {
        let config = MaxConfig.load()
        guard config.telegramEnabled,
              let t = SecretStore.secret(forKey: "telegram-bot"), !t.isEmpty else {
            stop(); return
        }
        guard !running else { return }
        token = t
        running = true
        pollTask = Task { [weak self] in
            await self?.primeOffset()  // skip messages sent before we came online
            await self?.pollLoop()
        }
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// Fast initial call to advance past any backlog so we don't reply to old
    /// messages on startup.
    private func primeOffset() async {
        guard let results = await fetchUpdates(timeout: 0) else { return }
        for update in results {
            if let id = update["update_id"] as? Int { offset = max(offset, id + 1) }
        }
    }

    private func pollLoop() async {
        while running && !Task.isCancelled {
            guard let results = await fetchUpdates(timeout: 30) else {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // back off on error
                continue
            }
            for update in results {
                if let id = update["update_id"] as? Int { offset = max(offset, id + 1) }
                handleUpdate(update)
            }
        }
    }

    private func fetchUpdates(timeout: Int) async -> [[String: Any]]? {
        var comps = URLComponents(string: "https://api.telegram.org/bot\(token)/getUpdates")!
        comps.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "timeout", value: String(timeout)),
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeout + 15)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let obj = JSON.decode(data), obj["ok"] as? Bool == true,
                  let results = obj["result"] as? [[String: Any]] else {
                if let obj = JSON.decode(data), obj["ok"] as? Bool == false {
                    ChannelLog.write("telegram: API error \(obj["description"] ?? "?") — check the bot token")
                }
                return nil
            }
            return results
        } catch {
            return nil
        }
    }

    private func handleUpdate(_ update: [String: Any]) {
        guard let message = update["message"] as? [String: Any],
              let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let from = message["from"] as? [String: Any],
              let chat = message["chat"] as? [String: Any] else { return }

        if from["is_bot"] as? Bool == true { return }
        let userId = String(describing: from["id"] as? Int ?? 0)
        let chatId = String(describing: chat["id"] as? Int ?? 0)
        guard userId != "0", chatId != "0" else { return }

        let allow = MaxConfig.load().telegramAllowlist
        guard allow.contains(userId) else {
            let name = from["username"] as? String ?? "?"
            ChannelLog.write("telegram: ignored message from \(name) (id \(userId)) — not in allowlist")
            return
        }

        let token = self.token
        ChannelRouter.shared.handle(key: "telegram-\(chatId)", text: text) { reply in
            Self.sendReply(chatId: chatId, text: reply, token: token)
        }
    }

    nonisolated static func sendReply(chatId: String, text: String, token: String) {
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSON.encode(["chat_id": chatId, "text": String(text.prefix(4000))])
        URLSession.shared.dataTask(with: request).resume()
    }
}
