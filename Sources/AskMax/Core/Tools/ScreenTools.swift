import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

// MARK: - see_screen: pixel vision (Screen Recording permission)

struct SeeScreenTool: MaxTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "see_screen",
            description: """
            Take a screenshot so you can SEE what's on the user's screen — the visual layout, \
            images, errors, whatever app they're looking at. target "window" captures only the \
            frontmost window (preferred — less noise); "screen" captures the full display. \
            For pure text content prefer read_screen_text (cheaper, more private).
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "target": [
                        "type": "string",
                        "enum": ["window", "screen"],
                        "description": "What to capture (default: window)",
                    ],
                ],
                "required": [],
            ]
        )
    }

    func summary(input: [String: Any]) -> String {
        "looking at the \(input["target"] as? String ?? "window")"
    }

    func execute(input: [String: Any]) async -> ToolOutcome {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .fail(
                "Screen Recording permission is not granted. macOS just showed a prompt — " +
                "tell the user to enable AskMax in System Settings → Privacy & Security → " +
                "Screen & System Audio Recording, then try again."
            )
        }

        let target = input["target"] as? String ?? "window"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmax-shot-\(UUID().uuidString.prefix(8)).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var frontAppName = "screen"
        var command = "/usr/sbin/screencapture -x -t png \(tmp.path)"
        if target == "window" {
            if let (windowID, appName) = Self.frontmostWindow() {
                frontAppName = appName
                command = "/usr/sbin/screencapture -x -t png -l \(windowID) \(tmp.path)"
            }
        }

        let result = await ExecTool.runShell(command, timeout: 15)
        if result.isError { return result }
        guard let image = Self.jpegPayload(from: tmp, maxPixels: 1500, quality: 0.7) else {
            return .fail("captured, but could not encode the screenshot")
        }
        return .image("Screenshot of \(frontAppName) (\(Date().formatted(date: .omitted, time: .standard)))", image)
    }

    /// Frontmost app's main on-screen window ID, for `screencapture -l`.
    static func frontmostWindow() -> (CGWindowID, String)? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in info {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = window[kCGWindowNumber as String] as? Int else { continue }
            let name = frontApp.localizedName ?? "front window"
            return (CGWindowID(id), name)
        }
        return nil
    }

    /// Downscale + JPEG-encode to keep token cost sane (~1500px long edge).
    static func jpegPayload(from url: URL, maxPixels: CGFloat, quality: CGFloat) -> ImagePayload? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return ImagePayload(base64: data.base64EncodedString(), mediaType: "image/jpeg")
    }
}

// MARK: - read_screen_text: Accessibility-based text vision (no pixels leave the Mac)

struct ReadScreenTextTool: MaxTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "read_screen_text",
            description: """
            Read the text content of the frontmost window via macOS Accessibility — no screenshot, \
            no pixels sent anywhere. Use this for articles, dialogs, code, chats: anything where \
            the words matter more than the visuals. Returns app name, window title and visible text.
            """,
            inputSchema: [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [],
            ]
        )
    }

    func summary(input: [String: Any]) -> String { "reading the front window" }

    func execute(input: [String: Any]) async -> ToolOutcome {
        await MainActor.run { Self.readFrontWindow() }
    }

    @MainActor
    static func readFrontWindow() -> ToolOutcome {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        guard trusted else {
            return .fail(
                "Accessibility permission is not granted. macOS just showed a prompt — " +
                "tell the user to enable AskMax in System Settings → Privacy & Security → " +
                "Accessibility, then try again."
            )
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .fail("no frontmost application")
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef)
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return .fail("could not access the front window of \(frontApp.localizedName ?? "the app")")
        }
        let window = windowRef as! AXUIElement

        var pieces: [String] = []
        var seen = Set<String>()
        var budget = 800
        collect(element: window, depth: 0, pieces: &pieces, seen: &seen, budget: &budget)

        let title = stringAttribute(window, kAXTitleAttribute) ?? ""
        var text = pieces.joined(separator: "\n")
        if text.count > 40_000 { text = String(text.prefix(40_000)) + "\n…[truncated]" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .fail(
                "\(frontApp.localizedName ?? "App") exposes no readable text via Accessibility " +
                "(some apps don't). Try see_screen instead."
            )
        }
        return .ok("App: \(frontApp.localizedName ?? "?")\nWindow: \(title)\n---\n\(text)")
    }

    private static func collect(
        element: AXUIElement, depth: Int,
        pieces: inout [String], seen: inout Set<String>, budget: inout Int
    ) {
        guard depth < 24, budget > 0 else { return }
        budget -= 1

        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = stringAttribute(element, attribute),
               s.count > 1, s.count < 8_000, !seen.contains(s) {
                seen.insert(s)
                pieces.append(s)
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children.prefix(60) {
            collect(element: child, depth: depth + 1, pieces: &pieces, seen: &seen, budget: &budget)
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
