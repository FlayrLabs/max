import Foundation

/// Prevents the Mac from idle-sleeping (via `caffeinate`) so loops and channels
/// keep running when you're away. Only meaningful while logged in; a laptop with
/// the lid closed still sleeps regardless. The mini (no lid, on AC) stays up.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    private var process: Process?

    private init() {}

    func apply() {
        MaxConfig.load().keepAwake ? start() : stop()
    }

    private func start() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "-s"] // prevent idle + system sleep
        do {
            try p.run()
            process = p
        } catch {
            process = nil
        }
    }

    private func stop() {
        process?.terminate()
        process = nil
    }
}
