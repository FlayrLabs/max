import SwiftUI
import AppKit
import Carbon

/// Records a global summon shortcut. Click the field, then press a combination.
///
/// Capture is a real AppKit control (a clicked NSButton naturally becomes first
/// responder, so its keyDown/performKeyEquivalent reliably receive the keystroke) —
/// SwiftUI NSEvent monitors and hidden background views did not. Every keypress is
/// logged to ~/.max/hotkey-debug.log for diagnosis.
struct HotKeyRecorder: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            RecorderControl(label: state.config.hotKeyLabel) { code, carbon, label in
                state.config.hotKeyCode = code
                state.config.hotKeyCarbonModifiers = carbon
                state.config.hotKeyLabel = label
                state.saveConfig()
                state.applyHotKey()
            }
            .frame(width: 220, height: 30)

            if state.config.hotKeyLabel != "⌥Space" {
                Button("Reset") {
                    state.config.hotKeyCode = 49
                    state.config.hotKeyCarbonModifiers = Int(optionKey)
                    state.config.hotKeyLabel = "⌥Space"
                    state.saveConfig()
                    state.applyHotKey()
                }
                .controlSize(.small)
            }
        }
    }
}

private struct RecorderControl: NSViewRepresentable {
    let label: String
    let onCapture: (Int, Int, String) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.bezelStyle = .rounded
        b.onCapture = onCapture
        b.baseLabel = label
        return b
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onCapture = onCapture
        nsView.baseLabel = label
    }
}

final class RecorderButton: NSButton {
    var onCapture: ((Int, Int, String) -> Void)?
    var baseLabel: String = "⌥Space" { didSet { if !recording { title = baseLabel } } }

    private var recording = false {
        didSet { title = recording ? "Press a shortcut… (Esc cancels)" : baseLabel; needsDisplay = true }
    }

    /// Standalone keys that are safe as a bare summon shortcut (no modifier needed).
    private static let functionKeys: Set<Int> =
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() {
        title = baseLabel
        font = .systemFont(ofSize: 12, weight: .semibold)
        setButtonType(.momentaryChange)
        focusRingType = .default
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if recording { endRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        let ok = window?.makeFirstResponder(self) ?? false
        HotKeyDebug.log("startRecording — firstResponder=\(ok), keyWindow=\(window?.isKeyWindow ?? false)")
    }

    private func endRecording() {
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if !capture(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording, capture(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult
    private func capture(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = carbonModifiers(mods)
        HotKeyDebug.log("key code=\(event.keyCode) carbon=\(carbon) chars=\(event.charactersIgnoringModifiers ?? "")")

        if event.keyCode == 53 { HotKeyDebug.log("esc — cancel"); endRecording(); return true }

        let hasModifier = (carbon & ~UInt32(shiftKey)) != 0
        let isFunctionKey = Self.functionKeys.contains(Int(event.keyCode))
        guard hasModifier || isFunctionKey else {
            HotKeyDebug.log("rejected — needs a non-shift modifier (or a function key)")
            return true // consume but keep waiting
        }

        let label = labelString(mods: mods, event: event)
        HotKeyDebug.log("CAPTURED \(label) (code \(event.keyCode), carbon \(carbon)) — saved")
        onCapture?(Int(event.keyCode), Int(carbon), label)
        endRecording()
        return true
    }

    private func carbonModifiers(_ mods: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if mods.contains(.command) { c |= UInt32(cmdKey) }
        if mods.contains(.option) { c |= UInt32(optionKey) }
        if mods.contains(.control) { c |= UInt32(controlKey) }
        if mods.contains(.shift) { c |= UInt32(shiftKey) }
        return c
    }

    private func labelString(mods: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + keyName(event)
    }

    private func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 105: return "F13"; case 107: return "F14"; case 113: return "F15"; case 106: return "F16"
        case 64: return "F17"; case 79: return "F18"; case 80: return "F19"; case 90: return "F20"
        default:
            let ch = event.charactersIgnoringModifiers ?? ""
            return ch.isEmpty ? "Key\(event.keyCode)" : ch.uppercased()
        }
    }
}

/// Lightweight file log so we can see whether capture fires and what was pressed.
enum HotKeyDebug {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".max/hotkey-debug.log")

    static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
