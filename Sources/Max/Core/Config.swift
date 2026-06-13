import Foundation
import Security

/// Where Max keeps everything: ~/.max/
/// soul.md, config.json, loops.json, sessions/*.jsonl
enum MaxPaths {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".max", isDirectory: true)
    }
    static var soulFile: URL { root.appendingPathComponent("soul.md") }
    static var configFile: URL { root.appendingPathComponent("config.json") }
    static var loopsFile: URL { root.appendingPathComponent("loops.json") }
    static var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    static var loopLogsDir: URL { root.appendingPathComponent("loop-logs", isDirectory: true) }

    static func ensure() {
        let fm = FileManager.default
        for dir in [root, sessionsDir, loopLogsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case ollama

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .ollama: return "Local (Ollama)"
        }
    }
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openai: return "gpt-5.2"
        case .ollama: return "llama3.2"
        }
    }
    var models: [String] {
        switch self {
        case .anthropic:
            return ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-fable-5"]
        case .openai:
            return ["gpt-5.2", "gpt-5.1", "gpt-5.1-codex"]
        case .ollama:
            return ["llama3.2", "qwen2.5", "mistral"] // placeholders — real list comes from /api/tags
        }
    }
    var needsAPIKey: Bool { self != .ollama }
}

enum ExecApprovalMode: String, Codable, CaseIterable, Identifiable {
    case auto   // run commands without asking (TARS mode)
    case ask    // surface each command for approval in chat

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto: return "Full access — run commands automatically"
        case .ask: return "Ask before running commands"
        }
    }
}

/// Another Mac the user owns, reachable over SSH (LAN or Tailscale). Max can
/// run commands on it via the remote_exec tool and is told it exists.
struct RemoteDevice: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""          // short name Max targets, e.g. "macbook"
    var host: String = ""          // IP or hostname
    var user: String = ""          // SSH user
    var port: Int = 22
    var identityFile: String = ""  // optional path to an SSH private key
    var note: String = ""          // what this machine is, for Max's awareness
}

struct MaxConfig: Codable, Equatable {
    var userName: String = ""
    var provider: LLMProviderKind = .anthropic
    var model: String = LLMProviderKind.anthropic.defaultModel
    var execApproval: ExecApprovalMode = .ask   // safer default; full-access is opt-in
    var onboarded: Bool = false
    var acknowledgedRisk: Bool = false          // accepted the full-access disclaimer
    var paused: Bool = false                    // kill switch — blocks all tool runs
    var commandDenylist: [String] = []          // user patterns to always block
    var useDefaultDenylist: Bool = true         // also block the built-in dangerous set
    var dailySpendLimitUSD: Double = 10         // sane default cap; 0 = unlimited (set in Settings)
    // Global summon shortcut. Defaults to ⌥Space. keyCode is the virtual key;
    // modifiers is the Carbon modifier mask (optionKey = 2048).
    var hotKeyCode: Int = 49                    // kVK_Space
    var hotKeyCarbonModifiers: Int = 2048       // optionKey
    var hotKeyLabel: String = "⌥Space"
    var allowScreenVision: Bool = true
    var loopsCanSeeScreen: Bool = false
    var ollamaBaseURL: String = "http://127.0.0.1:11434"
    var imessageEnabled: Bool = false
    var imessageAllowlist: [String] = []
    /// Your own iMessage handle (phone or Apple ID email). Texting this from
    /// your phone creates a note-to-self thread that Max reads and replies in.
    var imessageSelfHandle: String = ""
    var discordEnabled: Bool = false
    var discordAllowlist: [String] = []   // Discord user IDs allowed to command Max
    var slackEnabled: Bool = false
    var slackAllowlist: [String] = []     // Slack user IDs allowed to command Max
    var telegramEnabled: Bool = false
    var telegramAllowlist: [String] = []  // Telegram user IDs allowed to command Max
    var devices: [RemoteDevice] = []      // other Macs Max can control over SSH
    var keepAwake: Bool = false           // prevent idle sleep so loops/channels stay reachable
    var fontFamily: String = ""   // empty = system font
    var fontSize: Double = 13.5   // base size for chat text

    init() {}

    // Tolerant decoding: new fields fall back to defaults so an older
    // config.json never wipes the user's settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        provider = try c.decodeIfPresent(LLMProviderKind.self, forKey: .provider) ?? .anthropic
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? LLMProviderKind.anthropic.defaultModel
        execApproval = try c.decodeIfPresent(ExecApprovalMode.self, forKey: .execApproval) ?? .ask
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
        acknowledgedRisk = try c.decodeIfPresent(Bool.self, forKey: .acknowledgedRisk) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        commandDenylist = try c.decodeIfPresent([String].self, forKey: .commandDenylist) ?? []
        useDefaultDenylist = try c.decodeIfPresent(Bool.self, forKey: .useDefaultDenylist) ?? true
        dailySpendLimitUSD = try c.decodeIfPresent(Double.self, forKey: .dailySpendLimitUSD) ?? 10
        hotKeyCode = try c.decodeIfPresent(Int.self, forKey: .hotKeyCode) ?? 49
        hotKeyCarbonModifiers = try c.decodeIfPresent(Int.self, forKey: .hotKeyCarbonModifiers) ?? 2048
        hotKeyLabel = try c.decodeIfPresent(String.self, forKey: .hotKeyLabel) ?? "⌥Space"
        allowScreenVision = try c.decodeIfPresent(Bool.self, forKey: .allowScreenVision) ?? true
        loopsCanSeeScreen = try c.decodeIfPresent(Bool.self, forKey: .loopsCanSeeScreen) ?? false
        ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://127.0.0.1:11434"
        imessageEnabled = try c.decodeIfPresent(Bool.self, forKey: .imessageEnabled) ?? false
        imessageAllowlist = try c.decodeIfPresent([String].self, forKey: .imessageAllowlist) ?? []
        imessageSelfHandle = try c.decodeIfPresent(String.self, forKey: .imessageSelfHandle) ?? ""
        discordEnabled = try c.decodeIfPresent(Bool.self, forKey: .discordEnabled) ?? false
        discordAllowlist = try c.decodeIfPresent([String].self, forKey: .discordAllowlist) ?? []
        slackEnabled = try c.decodeIfPresent(Bool.self, forKey: .slackEnabled) ?? false
        slackAllowlist = try c.decodeIfPresent([String].self, forKey: .slackAllowlist) ?? []
        telegramEnabled = try c.decodeIfPresent(Bool.self, forKey: .telegramEnabled) ?? false
        telegramAllowlist = try c.decodeIfPresent([String].self, forKey: .telegramAllowlist) ?? []
        devices = try c.decodeIfPresent([RemoteDevice].self, forKey: .devices) ?? []
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13.5
    }

    static func load() -> MaxConfig {
        guard let data = try? Data(contentsOf: MaxPaths.configFile),
              let cfg = try? JSONDecoder().decode(MaxConfig.self, from: data) else {
            return MaxConfig()
        }
        return cfg
    }

    func save() {
        MaxPaths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: MaxPaths.configFile, options: .atomic)
        }
    }
}

enum Soul {
    static let defaultSoul = """
    # Soul

    You are Max — a personal assistant living on this Mac. You are honest, direct and capable, \
    with a dry sense of humor used sparingly. You get things done and report back tightly: \
    what you found, what you did, what's left.

    ## How to behave
    - Act decisively. For routine operations on this Mac, just do it and say what you did.
    - Confirm before anything destructive or irreversible.
    - Keep answers short. This is a chat pill, not a term paper.
    """

    static func load() -> String {
        if let s = try? String(contentsOf: MaxPaths.soulFile, encoding: .utf8), !s.isEmpty {
            return s
        }
        return defaultSoul
    }

    static func save(_ text: String) {
        MaxPaths.ensure()
        try? text.write(to: MaxPaths.soulFile, atomically: true, encoding: .utf8)
    }
}

/// Secret storage backed by the macOS Keychain.
///
/// Keys and tokens live as encrypted generic-password items, gated to Max by
/// its (now stable) code signature — never in plaintext on disk. This works
/// without recurring password prompts because the app is signed with a stable
/// self-signed identity (see scripts/make-signing-cert.sh); the Keychain ACL is
/// pinned to that signature's designated requirement, which no longer changes
/// across rebuilds. Items use `kSecAttrAccessibleAfterFirstUnlock` so loops and
/// channels can still read them while the screen is locked.
///
/// Anything found in the old 0600 `credentials.json` is migrated into the
/// Keychain once, then that file is deleted.
enum SecretStore {
    static func apiKey(for provider: LLMProviderKind) -> String? {
        secret(forKey: provider.rawValue)
    }

    static func setAPIKey(_ key: String, for provider: LLMProviderKind) {
        setSecret(key, forKey: provider.rawValue)
    }

    static func secret(forKey key: String) -> String? {
        Keychain.get(forKey: key)
    }

    static func setSecret(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, forKey: key)
    }

    /// One-time move of any legacy plaintext secrets into the Keychain, then
    /// remove the file so nothing sensitive is left on disk.
    static func migrateLegacyFileIfNeeded() {
        let fileURL = MaxPaths.root.appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        for (key, value) in dict where !value.isEmpty {
            if Keychain.get(forKey: key) == nil {
                Keychain.set(value, forKey: key)
            }
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Generic string-keyed Keychain access. Service is namespaced per key so each
/// secret is its own item.
enum Keychain {
    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.flayrlabs.max.\(key)",
            kSecAttrAccount as String: "secret",
        ]
    }

    static func set(_ value: String, forKey key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        // After-first-unlock: readable while the screen is locked (needed for
        // loops/channels running in the background), but not before first login.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(forKey key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
