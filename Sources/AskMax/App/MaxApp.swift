import SwiftUI
import AppKit

@main
struct AskMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Non-activating floating panel that can still take keyboard focus — the
/// Spotlight trick. The pill is borderless; the chat is `titled` so it gets
/// native traffic lights and native edge/corner resizing, while a transparent
/// title bar keeps the glass look.
final class FloatingPanel: NSPanel {
    init(size: NSSize, titled: Bool = false) {
        var style: NSWindow.StyleMask = [.nonactivatingPanel]
        if titled {
            style.insert(.titled)
            style.insert(.closable)
            style.insert(.miniaturizable)
            style.insert(.resizable)
            style.insert(.fullSizeContentView)
        } else {
            style.insert(.borderless)
        }
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = titled // system shadow for the chat window; pill draws its own
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true

        if titled {
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            title = "AskMax"
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var pillPanel: FloatingPanel!
    private var chatPanel: FloatingPanel!
    private var settingsWindow: NSWindow?
    private var consentWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    private let pillSize = NSSize(width: 640, height: 120)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MaxPaths.ensure()
        SecretStore.migrateLegacyFileIfNeeded() // move any plaintext keys into the Keychain, then delete the file

        setupPill()
        setupChat()
        setupStatusItem()

        AppState.shared.onChatOpenChanged = { [weak self] open in
            self?.setChatVisible(open)
        }

        reloadHotKey()
        AppState.shared.onHotKeyChanged = { [weak self] in self?.reloadHotKey() }

        LoopScheduler.shared.start()
        IMessageBridge.shared.startIfEnabled()
        TelegramChannel.shared.startIfEnabled()
        DiscordChannel.shared.startIfEnabled()
        SlackChannel.shared.startIfEnabled()
        KeepAwake.shared.apply()

        if !AppState.shared.config.acknowledgedRisk {
            showConsent()
        } else if AppState.shared.needsOnboarding {
            showSettings()
        }
        pillPanel.orderFrontRegardless()
        focusPill()
    }

    private func showConsent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "AskMax"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: RiskConsentView(
            onAccept: { [weak self] in
                AppState.shared.acknowledgeRisk()
                self?.consentWindow?.close()
                self?.consentWindow = nil
                if AppState.shared.needsOnboarding {
                    self?.showSettings()
                } else {
                    NSApp.setActivationPolicy(.accessory)
                }
            },
            onQuit: { NSApp.terminate(nil) }
        ))
        consentWindow = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: Pill

    private func setupPill() {
        pillPanel = FloatingPanel(size: pillSize)
        let host = NSHostingView(
            rootView: PillView().environmentObject(AppState.shared)
        )
        host.frame = NSRect(origin: .zero, size: pillSize)
        pillPanel.contentView = host
        positionPill()
    }

    private func positionPill() {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let x = vis.midX - pillSize.width / 2
        let y = vis.minY + 12
        pillPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func focusPill() {
        pillPanel.makeKeyAndOrderFront(nil)
        FocusBus.shared.requestPillFocus()
    }

    // MARK: Chat

    private let chatSizeDefaultsKey = "chatPanelSize"

    private func chatSize() -> NSSize {
        guard let screen = NSScreen.main else { return NSSize(width: 880, height: 560) }
        let vis = screen.visibleFrame
        // User-resized size wins, clamped to what fits above the pill.
        if let saved = UserDefaults.standard.string(forKey: chatSizeDefaultsKey) {
            var size = NSSizeFromString(saved)
            if size.width >= 460, size.height >= 300 {
                size.width = min(size.width, vis.width - 24)
                size.height = min(size.height, vis.height - pillSize.height - 36)
                return size
            }
        }
        return NSSize(
            width: min(900, vis.width - 64),
            height: min(580, vis.height - 220)
        )
    }

    private func setupChat() {
        let size = chatSize()
        chatPanel = FloatingPanel(size: size, titled: true)
        chatPanel.minSize = NSSize(width: 460, height: 300)
        chatPanel.delegate = self  // intercept the red traffic light → hide, not destroy
        let host = NSHostingView(
            rootView: ChatView().environmentObject(AppState.shared)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        chatPanel.contentView = host
        positionChat()
        chatPanel.alphaValue = 0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chatDidResize),
            name: NSWindow.didEndLiveResizeNotification,
            object: chatPanel
        )
    }

    @objc private func chatDidResize() {
        UserDefaults.standard.set(
            NSStringFromSize(chatPanel.frame.size),
            forKey: chatSizeDefaultsKey
        )
    }

    private func positionChat() {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let size = chatSize()
        chatPanel.setContentSize(size)
        let x = vis.midX - size.width / 2
        // Sits above the pill with a gap, roughly centered in remaining space.
        let y = vis.minY + 12 + pillSize.height + 8
        chatPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func setChatVisible(_ visible: Bool) {
        if visible {
            positionChat()
            chatPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                chatPanel.animator().alphaValue = 1
            }
            pillPanel.makeKeyAndOrderFront(nil)
            FocusBus.shared.requestPillFocus()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                chatPanel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    if AppState.shared.chatOpen == false {
                        self?.chatPanel.orderOut(nil)
                    }
                }
            })
        }
    }

    private func reloadHotKey() {
        let config = AppState.shared.config
        hotKey = HotKey(
            keyCode: UInt32(config.hotKeyCode),
            modifiers: UInt32(config.hotKeyCarbonModifiers)
        ) { [weak self] in
            self?.summon()
        }
    }

    private func summon() {
        if AppState.shared.chatOpen {
            AppState.shared.closeChat()
        } else {
            positionPill()
            pillPanel.orderFrontRegardless()
            focusPill()
        }
    }

    // MARK: Status item + settings

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = statusBarDuck()
        }
        let menu = NSMenu()
        menu.delegate = self
        summonItem = NSMenuItem(title: "Summon Max", action: #selector(menuSummon), keyEquivalent: "")
        menu.addItem(summonItem)
        menu.addItem(NSMenuItem.separator())
        pauseItem = NSMenuItem(title: "Pause Max", action: #selector(menuTogglePause), keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "New Conversation", action: #selector(menuClear), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit AskMax", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private var pauseItem: NSMenuItem!
    private var summonItem: NSMenuItem!

    /// Menu-bar duck, scaled to fit and dimmed when paused.
    private func statusBarDuck() -> NSImage {
        let paused = AppState.shared.config.paused
        if let url = Bundle.main.url(forResource: "DuckGlyph", withExtension: "png"),
           let duck = NSImage(contentsOf: url) {
            let target = NSSize(width: 18, height: 18)
            let scaled = NSImage(size: target)
            scaled.lockFocus()
            duck.draw(in: NSRect(origin: .zero, size: target),
                      from: .zero, operation: .sourceOver,
                      fraction: paused ? 0.4 : 1.0)
            scaled.unlockFocus()
            return scaled
        }
        return NSImage(systemSymbolName: paused ? "pause.circle.fill" : "bubbles.and.sparkles.fill",
                       accessibilityDescription: "Max") ?? NSImage()
    }

    @objc private func menuTogglePause() {
        AppState.shared.setPaused(!AppState.shared.config.paused)
        refreshPauseItem()
        statusItem.button?.image = statusBarDuck()
    }

    private func refreshPauseItem() {
        let paused = AppState.shared.config.paused
        pauseItem.title = paused ? "Resume Max" : "Pause Max"
        pauseItem.state = paused ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPauseItem()
        summonItem.title = "Summon Max (\(AppState.shared.config.hotKeyLabel))"
    }

    @objc private func menuSummon() { summon() }
    @objc private func menuClear() { AppState.shared.clearConversation() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc func menuSettings() { showSettings() }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "AskMax"
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Float above the always-on-top pill/chat panels, otherwise an
            // accessory app's settings window opens behind them.
            window.level = .floating
            window.contentView = NSHostingView(
                rootView: SettingsRootView().environmentObject(AppState.shared)
            )
            settingsWindow = window
        }
        // Briefly become a regular app so the window reliably takes focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    // Drop the dock icon again once settings closes.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Red traffic light on the chat just hides it (back to the pill); the
    // conversation persists. Don't actually close/destroy the panel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === chatPanel {
            AppState.shared.closeChat()
            return false
        }
        return true
    }
}

/// Tiny signal bus so AppKit can ask the SwiftUI pill to grab keyboard focus.
@MainActor
final class FocusBus: ObservableObject {
    static let shared = FocusBus()
    @Published var pillFocusTick = 0
    var onOpenSettings: (() -> Void)?
    func requestPillFocus() { pillFocusTick += 1 }
    func openSettings() { onOpenSettings?() }
}
