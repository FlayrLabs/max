import SwiftUI
import AppKit
import Carbon

/// Records a global summon shortcut. Click to listen for the next modifier+key
/// combination, which is saved and re-registered immediately.
struct HotKeyRecorder: View {
    @EnvironmentObject var state: AppState
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press a shortcut… (Esc to cancel)" : state.config.hotKeyLabel)
                    .font(.system(size: 12, weight: recording ? .regular : .semibold,
                                  design: .rounded))
                    .frame(minWidth: 180)
            }
            .controlSize(.large)

            if state.config.hotKeyLabel != "⌥Space" {
                Button("Reset") { reset() }
                    .controlSize(.small)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // consume the keypress while recording
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    private func reset() {
        state.config.hotKeyCode = 49
        state.config.hotKeyCarbonModifiers = Int(optionKey)
        state.config.hotKeyLabel = "⌥Space"
        state.saveConfig()
        state.applyHotKey()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return } // Escape cancels

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = carbonModifiers(mods)
        // Require at least one non-shift modifier so we don't capture a bare key
        // (which would hijack normal typing).
        guard (carbon & ~UInt32(shiftKey)) != 0 else { return }

        state.config.hotKeyCode = Int(event.keyCode)
        state.config.hotKeyCarbonModifiers = Int(carbon)
        state.config.hotKeyLabel = label(mods: mods, event: event)
        state.saveConfig()
        state.applyHotKey()
        stop()
    }

    private func carbonModifiers(_ mods: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if mods.contains(.command) { c |= UInt32(cmdKey) }
        if mods.contains(.option) { c |= UInt32(optionKey) }
        if mods.contains(.control) { c |= UInt32(controlKey) }
        if mods.contains(.shift) { c |= UInt32(shiftKey) }
        return c
    }

    private func label(mods: NSEvent.ModifierFlags, event: NSEvent) -> String {
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
        default:
            let ch = event.charactersIgnoringModifiers ?? ""
            return ch.isEmpty ? "Key\(event.keyCode)" : ch.uppercased()
        }
    }
}
