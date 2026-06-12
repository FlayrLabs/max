import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: Section? = .profile

    enum Section: String, CaseIterable, Identifiable {
        case profile, model, safety, devices, loops, imessage, channels
        var id: String { rawValue }
        var title: String {
            switch self {
            case .profile: return "You & Soul"
            case .model: return "Model"
            case .safety: return "Safety"
            case .devices: return "Devices"
            case .loops: return "Loops"
            case .imessage: return "iMessage"
            case .channels: return "Channels"
            }
        }
        var icon: String {
            switch self {
            case .profile: return "person.fill"
            case .model: return "brain"
            case .safety: return "shield.lefthalf.filled"
            case .devices: return "macbook.and.iphone"
            case .loops: return "arrow.triangle.2.circlepath"
            case .imessage: return "message.fill"
            case .channels: return "bubble.left.and.bubble.right.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 195, max: 220)
        } detail: {
            detail
                .navigationTitle(selection?.title ?? "AskMax")
        }
        .frame(minWidth: 740, idealWidth: 780, minHeight: 560, idealHeight: 600)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .profile {
        case .profile: ProfileTab()
        case .model: ModelTab()
        case .safety: SafetyTab()
        case .devices: DevicesTab()
        case .loops: LoopsTab()
        case .imessage: IMessageTab()
        case .channels: ChannelsTab()
        }
    }
}

// MARK: - Profile + soul.md

private struct ProfileTab: View {
    @EnvironmentObject var state: AppState
    @State private var soul: String = Soul.load()

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your name").font(.system(size: 12, weight: .semibold))
                TextField("Ahmed", text: $state.config.userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onChange(of: state.config.userName) { state.saveConfig() }
            }

            HStack {
                Text("Summon shortcut").font(.system(size: 12, weight: .semibold))
                HotKeyRecorder()
            }

            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Picker("Font", selection: $state.config.fontFamily) {
                            Text("System (San Francisco)").tag("")
                            Divider()
                            ForEach(fontFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .frame(maxWidth: 280)
                        .onChange(of: state.config.fontFamily) { state.saveConfig() }

                        Slider(value: $state.config.fontSize, in: 11...20, step: 0.5) {
                            Text("Size")
                        }
                        .frame(maxWidth: 180)
                        .onChange(of: state.config.fontSize) { state.saveConfig() }

                        Text(String(format: "%.1f pt", state.config.fontSize))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                    }
                    Text("Hey — I'm Max. This is how the chat will look.")
                        .font(state.chatFont())
                        .padding(.top, 2)
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("soul.md").font(.system(size: 12, weight: .semibold))
                    Text("— who Max is and how he should behave. Saved to ~/.askmax/soul.md")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to default") {
                        soul = Soul.defaultSoul
                        Soul.save(soul)
                    }
                    .controlSize(.small)
                }
                TextEditor(text: $soul)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: soul) { Soul.save(soul) }
            }
        }
        .padding(16)
    }
}

// MARK: - Model & key

private struct ModelTab: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var savedFlash = false
    @State private var localModels: [String] = []
    @State private var localModelsNote = ""

    private var hasKey: Bool { !(SecretStore.apiKey(for: state.config.provider) ?? "").isEmpty }

    private var modelChoices: [String] {
        if state.config.provider == .ollama, !localModels.isEmpty { return localModels }
        return state.config.provider.models
    }

    var body: some View {
        Form {
            Picker("Provider", selection: $state.config.provider) {
                ForEach(LLMProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: state.config.provider) {
                state.config.model = state.config.provider.defaultModel
                apiKeyDraft = ""
                if state.config.provider == .ollama {
                    state.config.onboarded = true // no key needed for local models
                    fetchLocalModels()
                }
                state.saveConfig()
            }

            Picker("Model", selection: $state.config.model) {
                ForEach(modelChoices, id: \.self) { model in
                    Text(model).tag(model)
                }
                if !modelChoices.contains(state.config.model) {
                    Text(state.config.model).tag(state.config.model)
                }
            }
            .onChange(of: state.config.model) { state.saveConfig() }

            TextField("Custom model id", text: $state.config.model)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { state.saveConfig() }

            if state.config.provider == .ollama {
                LabeledContent("Ollama URL") {
                    HStack {
                        TextField("http://127.0.0.1:11434", text: $state.config.ollamaBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { state.saveConfig(); fetchLocalModels() }
                        Button("Refresh") { state.saveConfig(); fetchLocalModels() }
                    }
                }
                if !localModelsNote.isEmpty {
                    Text(localModelsNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("API key") {
                    HStack {
                        SecureField(hasKey ? "•••••••• saved in Keychain" : "paste key…", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button(savedFlash ? "Saved ✓" : "Save") {
                            SecretStore.setAPIKey(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  for: state.config.provider)
                            apiKeyDraft = ""
                            state.config.onboarded = true
                            state.saveConfig()
                            savedFlash = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedFlash = false }
                        }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section("Screen vision") {
                Toggle("Max can see the screen", isOn: $state.config.allowScreenVision)
                    .onChange(of: state.config.allowScreenVision) { state.saveConfig() }
                Toggle("Loops can see the screen", isOn: $state.config.loopsCanSeeScreen)
                    .disabled(!state.config.allowScreenVision)
                    .onChange(of: state.config.loopsCanSeeScreen) { state.saveConfig() }
                Text("Screenshots are sent to your model provider. `read_screen_text` reads text via Accessibility and sends no pixels. Scheduled loops stay blind unless you allow them above.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("Keys are stored encrypted in the macOS Keychain and only sent to the provider you picked. Local (Ollama) models run entirely on your machine — no key, nothing leaves the Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear {
            if state.config.provider == .ollama { fetchLocalModels() }
        }
    }

    /// Asks the Ollama server which models are installed (GET /api/tags).
    private func fetchLocalModels() {
        var base = state.config.ollamaBaseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/api/tags") else {
            localModelsNote = "Invalid Ollama URL"
            return
        }
        localModelsNote = "Checking \(base)…"
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let names = ((JSON.decode(data)?["models"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["name"] as? String }
                await MainActor.run {
                    localModels = names
                    if names.isEmpty {
                        localModelsNote = "Ollama is reachable but has no models. Run: ollama pull llama3.2"
                    } else {
                        localModelsNote = "\(names.count) installed model\(names.count == 1 ? "" : "s") found"
                        if !names.contains(state.config.model) {
                            state.config.model = names[0]
                            state.saveConfig()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    localModels = []
                    localModelsNote = "Could not reach Ollama at \(base) — is it running?"
                }
            }
        }
    }
}

// MARK: - iMessage

private struct IMessageTab: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var bridge = IMessageBridge.shared
    @State private var newHandle = ""

    var body: some View {
        Form {
            Toggle("Let me text Max", isOn: $state.config.imessageEnabled)
                .onChange(of: state.config.imessageEnabled) {
                    state.saveConfig()
                    state.config.imessageEnabled
                        ? IMessageBridge.shared.startIfEnabled()
                        : IMessageBridge.shared.stop()
                }

            Section("Text Max yourself") {
                TextField("Your number or Apple ID email", text: $state.config.imessageSelfHandle)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: state.config.imessageSelfHandle) {
                        state.saveConfig()
                        IMessageBridge.shared.startIfEnabled()
                    }
                Text("Put your own iMessage handle here, then text it from your iPhone (a note-to-self thread). Max reads that thread and replies in it — the same conversation continues on your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Other allowed senders (optional)") {
                ForEach(state.config.imessageAllowlist, id: \.self) { handle in
                    HStack {
                        Text(handle).font(.system(size: 12.5, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            state.config.imessageAllowlist.removeAll { $0 == handle }
                            state.saveConfig()
                        } label: { Image(systemName: "trash") }
                        .controlSize(.small)
                    }
                }
                HStack {
                    TextField("+1 555 123 4567 or you@icloud.com", text: $newHandle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addHandle() }
                    Button("Add") { addHandle() }
                        .disabled(newHandle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Max only ever responds to these handles. Add your own number/email and text yourself — Messages on this Mac picks it up.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Bridge", value: bridge.status)
                LabeledContent("Full Disk Access", value: bridge.hasFullDiskAccess ? "granted ✓" : "needed")
                if !bridge.hasFullDiskAccess {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Reading the Messages database requires adding AskMax under Full Disk Access. Sending replies will also prompt once to allow controlling Messages.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let error = bridge.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func addHandle() {
        let handle = newHandle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { return }
        if !state.config.imessageAllowlist.contains(handle) {
            state.config.imessageAllowlist.append(handle)
            state.saveConfig()
        }
        newHandle = ""
    }
}

// MARK: - Safety (approval, denylist, spend, kill switch)

private struct SafetyTab: View {
    @EnvironmentObject var state: AppState
    @State private var newPattern = ""
    @State private var todaySpend = SpendTracker.todaySpend()

    var body: some View {
        Form {
            Section("Command approval") {
                Picker("When chatting at this Mac", selection: $state.config.execApproval) {
                    ForEach(ExecApprovalMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: state.config.execApproval) { state.saveConfig() }
                Text("\"Ask\" pops a confirmation before Max runs shell, AppleScript, or remote commands you start from the pill. Loops and channel messages run unattended, so they can't prompt — the denylist below is their guard.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Disallowed commands") {
                Toggle("Block a built-in set of dangerous commands", isOn: $state.config.useDefaultDenylist)
                    .onChange(of: state.config.useDefaultDenylist) { state.saveConfig() }
                Text("Includes things like rm -rf /, disk erase, piping downloads to a shell, reading SSH keys, and dumping the Keychain.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)

                ForEach(state.config.commandDenylist, id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            state.config.commandDenylist.removeAll { $0 == pattern }
                            state.saveConfig()
                        } label: { Image(systemName: "trash") }.controlSize(.small)
                    }
                }
                HStack {
                    TextField("Add text to block (matched anywhere in a command)", text: $newPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addPattern() }
                    Button("Add") { addPattern() }
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Applies everywhere — pill, loops, and channels — regardless of approval mode.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            Section("Daily spend limit") {
                LabeledContent("Daily limit") {
                    HStack(spacing: 8) {
                        TextField("0.00", value: $state.config.dailySpendLimitUSD,
                                  format: .currency(code: "USD"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onSubmit { state.saveConfig() }
                        Button("Save") { state.saveConfig() }
                    }
                }
                LabeledContent("Spent today") {
                    HStack(spacing: 8) {
                        Text(todaySpend, format: .currency(code: "USD"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button { todaySpend = SpendTracker.todaySpend() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                }
                Text("Set to $0 for no limit. Estimated from token usage and model pricing; when today's spend reaches the limit, Max stops making new requests until tomorrow. Local (Ollama) models are free and don't count.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            Section("Kill switch") {
                Toggle("Pause Max (block all tool use)", isOn: Binding(
                    get: { state.config.paused },
                    set: { state.setPaused($0) }
                ))
                Text("Also available from the menu-bar icon. While paused, Max won't run any commands or respond on channels.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            Text("Max acts on AI instructions and can be wrong or manipulated by content it reads. These controls reduce risk but don't eliminate it. Audit everything it did in ~/.askmax/actions.log.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear { todaySpend = SpendTracker.todaySpend() }
    }

    private func addPattern() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        if !state.config.commandDenylist.contains(p) {
            state.config.commandDenylist.append(p)
            state.saveConfig()
        }
        newPattern = ""
    }
}

// MARK: - Channels (Discord + Slack)

private struct ChannelsTab: View {
    @EnvironmentObject var state: AppState
    @State private var telegramToken = ""
    @State private var discordToken = ""
    @State private var slackApp = ""
    @State private var slackBot = ""
    @State private var newTelegramId = ""
    @State private var newDiscordId = ""
    @State private var newSlackId = ""

    private var hasTelegramToken: Bool { SecretStore.secret(forKey: "telegram-bot") != nil }
    private var hasDiscordToken: Bool { SecretStore.secret(forKey: "discord-bot") != nil }
    private var hasSlackTokens: Bool {
        SecretStore.secret(forKey: "slack-app") != nil && SecretStore.secret(forKey: "slack-bot") != nil
    }

    var body: some View {
        Form {
            Text("Give Max its own identity on Telegram, Discord, or Slack with a real two-sided conversation. You create the bot, paste its token(s), and allowlist your own user ID.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Section("Availability") {
                Toggle("Keep this Mac awake", isOn: $state.config.keepAwake)
                    .onChange(of: state.config.keepAwake) {
                        state.saveConfig()
                        KeepAwake.shared.apply()
                    }
                Text("Prevents idle sleep so loops and channel messages keep working while you're away. Only applies while logged in — a laptop with the lid closed still sleeps; an always-on Mac like a mini stays reachable.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Section("Telegram (easiest)") {
                Toggle("Enable Telegram bot", isOn: $state.config.telegramEnabled)
                    .onChange(of: state.config.telegramEnabled) {
                        state.saveConfig()
                        state.config.telegramEnabled
                            ? TelegramChannel.shared.startIfEnabled()
                            : TelegramChannel.shared.stop()
                    }
                HStack {
                    SecureField(hasTelegramToken ? "•••••• bot token saved" : "Bot token from @BotFather", text: $telegramToken)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        SecretStore.setSecret(telegramToken, forKey: "telegram-bot")
                        telegramToken = ""
                        TelegramChannel.shared.stop(); TelegramChannel.shared.startIfEnabled()
                    }
                    .disabled(telegramToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                allowlistEditor(
                    title: "Allowed Telegram user IDs",
                    list: $state.config.telegramAllowlist,
                    draft: $newTelegramId
                )
                Text("In Telegram, message @BotFather → /newbot → copy the token. Then DM your new bot anything. To find your user ID, message @userinfobot — it replies with your numeric ID. Add that ID above.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Section("Discord") {
                Toggle("Enable Discord bot", isOn: $state.config.discordEnabled)
                    .onChange(of: state.config.discordEnabled) {
                        state.saveConfig()
                        state.config.discordEnabled
                            ? DiscordChannel.shared.startIfEnabled()
                            : DiscordChannel.shared.stop()
                    }
                HStack {
                    SecureField(hasDiscordToken ? "•••••• bot token saved" : "Bot token", text: $discordToken)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        SecretStore.setSecret(discordToken, forKey: "discord-bot")
                        discordToken = ""
                        DiscordChannel.shared.stop(); DiscordChannel.shared.startIfEnabled()
                    }
                    .disabled(discordToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                allowlistEditor(
                    title: "Allowed Discord user IDs",
                    list: $state.config.discordAllowlist,
                    draft: $newDiscordId
                )
                Text("In the Discord Developer Portal: create an app → Bot → enable the MESSAGE CONTENT intent → copy the token. Invite the bot to a server or DM it. Get your user ID via Discord Settings → Advanced → Developer Mode → right-click yourself → Copy User ID.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Section("Slack") {
                Toggle("Enable Slack bot", isOn: $state.config.slackEnabled)
                    .onChange(of: state.config.slackEnabled) {
                        state.saveConfig()
                        state.config.slackEnabled
                            ? SlackChannel.shared.startIfEnabled()
                            : SlackChannel.shared.stop()
                    }
                HStack {
                    SecureField(hasSlackTokens ? "•••••• app token saved" : "App-level token (xapp-…)", text: $slackApp)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        SecretStore.setSecret(slackApp, forKey: "slack-app")
                        slackApp = ""
                        SlackChannel.shared.stop(); SlackChannel.shared.startIfEnabled()
                    }
                    .disabled(slackApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    SecureField(hasSlackTokens ? "•••••• bot token saved" : "Bot token (xoxb-…)", text: $slackBot)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        SecretStore.setSecret(slackBot, forKey: "slack-bot")
                        slackBot = ""
                        SlackChannel.shared.stop(); SlackChannel.shared.startIfEnabled()
                    }
                    .disabled(slackBot.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                allowlistEditor(
                    title: "Allowed Slack user IDs",
                    list: $state.config.slackAllowlist,
                    draft: $newSlackId
                )
                Text("Create a Slack app → enable Socket Mode (generates the app-level token with connections:write) → add bot scopes chat:write + message.im, subscribe to message.im events → install to workspace for the bot token. Your user ID is in your Slack profile → More → Copy member ID.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    @ViewBuilder
    private func allowlistEditor(title: String, list: Binding<[String]>, draft: Binding<String>) -> some View {
        ForEach(list.wrappedValue, id: \.self) { id in
            HStack {
                Text(id).font(.system(size: 12, design: .monospaced))
                Spacer()
                Button(role: .destructive) {
                    list.wrappedValue.removeAll { $0 == id }
                    state.saveConfig()
                } label: { Image(systemName: "trash") }
                .controlSize(.small)
            }
        }
        HStack {
            TextField(title, text: draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addId(list: list, draft: draft) }
            Button("Add") { addId(list: list, draft: draft) }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addId(list: Binding<[String]>, draft: Binding<String>) {
        let id = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if !list.wrappedValue.contains(id) {
            list.wrappedValue.append(id)
            state.saveConfig()
        }
        draft.wrappedValue = ""
    }
}

// MARK: - Devices (other Macs over SSH)

private struct DevicesTab: View {
    @EnvironmentObject var state: AppState
    @State private var draft = RemoteDevice()
    @State private var testResult = ""

    var body: some View {
        Form {
            Text("Add your other Macs so Max is aware of them and can run commands on them over SSH (LAN or Tailscale). Set up passwordless key-based SSH to each first.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !state.config.devices.isEmpty {
                Section("Your Macs") {
                    ForEach(state.config.devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.system(size: 13, weight: .bold))
                                Text("\(device.user)@\(device.host)\(device.port == 22 ? "" : ":\(device.port)")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if !device.note.isEmpty {
                                    Text(device.note).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Test") { test(device) }
                                .controlSize(.small)
                            Button(role: .destructive) {
                                state.config.devices.removeAll { $0.id == device.id }
                                state.saveConfig()
                            } label: { Image(systemName: "trash") }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            Section("Add a Mac") {
                TextField("Name (e.g. macbook)", text: $draft.name).textFieldStyle(.roundedBorder)
                TextField("Host / IP (e.g. 100.85.14.80)", text: $draft.host).textFieldStyle(.roundedBorder)
                TextField("SSH user", text: $draft.user).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Port").font(.system(size: 12))
                    TextField("22", value: $draft.port, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                TextField("Identity file (optional, e.g. ~/.ssh/id_ed25519)", text: $draft.identityFile)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                TextField("Note — what is this machine? (helps Max)", text: $draft.note).textFieldStyle(.roundedBorder)
                Button("Add device") {
                    var d = draft
                    d.name = d.name.trimmingCharacters(in: .whitespaces)
                    d.host = d.host.trimmingCharacters(in: .whitespaces)
                    d.user = d.user.trimmingCharacters(in: .whitespaces)
                    guard !d.name.isEmpty, !d.host.isEmpty, !d.user.isEmpty else { return }
                    state.config.devices.append(d)
                    state.saveConfig()
                    draft = RemoteDevice()
                }
                .disabled(draft.name.isEmpty || draft.host.isEmpty || draft.user.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func test(_ device: RemoteDevice) {
        testResult = "Testing \(device.name)…"
        let tool = RemoteExecTool(devices: state.config.devices)
        Task {
            let outcome = await tool.execute(input: [
                "device": device.name,
                "command": "hostname; sw_vers -productVersion",
                "timeout_seconds": 15,
            ])
            await MainActor.run {
                testResult = (outcome.isError ? "❌ " : "✓ ") + outcome.content.replacingOccurrences(of: "\n", with: " ")
            }
        }
    }
}

// MARK: - Loops

private struct LoopsTab: View {
    @ObservedObject private var store = LoopStore.shared
    @ObservedObject private var scheduler = LoopScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loops are recurring Max runs. Create them in chat — \"every morning at 8, summarize my calendar\" — and manage them here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            if store.loops.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No loops yet").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                List {
                    ForEach(store.loops) { loop in
                        LoopRow(loop: loop, isRunning: scheduler.runningLoopIds.contains(loop.id))
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
    }
}

private struct LoopRow: View {
    let loop: MaxLoop
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { loop.enabled },
                    set: { _ in LoopStore.shared.toggle(id: loop.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

                Text(loop.name).font(.system(size: 13, weight: .bold))
                Text(loop.schedule.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Run now") { LoopScheduler.shared.runNow(loop) }
                    .controlSize(.small)
                    .disabled(isRunning)
                Button(role: .destructive) {
                    LoopStore.shared.remove(id: loop.id)
                } label: { Image(systemName: "trash") }
                .controlSize(.small)
            }
            Text(loop.prompt)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let summary = loop.lastSummary, !summary.isEmpty {
                Text("last: \(summary)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(loop.lastWasError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
