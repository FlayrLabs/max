import Foundation

/// Blocks commands matching the user's denylist (plus a built-in dangerous set).
/// Applied to every shell/AppleScript/remote command regardless of origin — so
/// it protects loops and channel-triggered runs that auto-approve.
enum CommandGuard {
    /// Conservative defaults: destructive disk/file ops, secret exfiltration,
    /// pipe-to-shell, fork bombs, SIP disable. Substring match, case-insensitive.
    static let builtinPatterns = [
        "rm -rf /", "rm -rf ~", "rm -rf /*", "rm -fr /", "rm -rf .",
        "mkfs", "dd of=/dev/", "/dev/rdisk", ">/dev/disk", "> /dev/disk",
        "diskutil erase", "diskutil partitiondisk", "diskutil reformat",
        "csrutil disable", "spctl --master-disable",
        ":(){", "fork bomb",
        "| sh", "|sh", "| bash", "|bash", "| zsh", "|zsh",
        "id_rsa", "id_ed25519", "/.ssh/id", "security dump-keychain",
        "security find-generic-password", "security find-internet-password",
    ]

    /// Returns the matched pattern if the command is blocked, else nil.
    static func blockedPattern(for command: String, config: MaxConfig) -> String? {
        let haystack = command.lowercased()
        var patterns = config.commandDenylist
        if config.useDefaultDenylist { patterns += builtinPatterns }
        for pattern in patterns {
            let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
            if !p.isEmpty, haystack.contains(p) { return pattern }
        }
        return nil
    }

    static func block(_ command: String) -> ToolOutcome? {
        if let pattern = blockedPattern(for: command, config: MaxConfig.load()) {
            return .fail("Blocked by the command denylist (matched \"\(pattern)\"). " +
                "Do not retry; tell the user this command is disallowed and why.")
        }
        return nil
    }
}

/// Tracks LLM spend per day (USD) and enforces a configurable daily cap.
/// Thread-safe and origin-agnostic; cloud models only (local Ollama is free).
enum SpendTracker {
    private static let lock = NSLock()

    /// USD per 1M tokens (input, output).
    private static let pricing: [String: (input: Double, output: Double)] = [
        "claude-fable-5": (10, 50),
        "claude-opus-4-8": (5, 25),
        "claude-opus-4-7": (5, 25),
        "claude-opus-4-6": (5, 25),
        "claude-sonnet-4-6": (3, 15),
        "claude-haiku-4-5": (1, 5),
        "gpt-5.2": (5, 15),
        "gpt-5.1": (5, 15),
        "gpt-5.1-codex": (5, 15),
    ]

    private static var fileURL: URL { MaxPaths.root.appendingPathComponent("spend.json") }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func load() -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return [:] }
        return obj
    }

    private static func save(_ dict: [String: Double]) {
        MaxPaths.ensure()
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func todaySpend() -> Double {
        lock.lock(); defer { lock.unlock() }
        return load()[todayKey()] ?? 0
    }

    static func record(model: String, inputTokens: Int, outputTokens: Int) {
        let price = pricing[model] ?? (input: 10, output: 30) // conservative default for unknown models
        let cost = Double(inputTokens) / 1_000_000 * price.input
            + Double(outputTokens) / 1_000_000 * price.output
        guard cost > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[todayKey(), default: 0] += cost
        // Prune to the last ~45 days.
        if all.count > 45 {
            for key in all.keys.sorted().prefix(all.count - 45) { all.removeValue(forKey: key) }
        }
        save(all)
    }

    static func isOverLimit(_ config: MaxConfig) -> Bool {
        config.dailySpendLimitUSD > 0 && todaySpend() >= config.dailySpendLimitUSD
    }
}

/// Append-only audit log of every tool Max runs. Lets you see exactly what the
/// agent did, after the fact.
enum ActionLog {
    static func write(_ line: String) {
        let url = MaxPaths.root.appendingPathComponent("actions.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
