import Foundation
import UserNotifications

// MARK: - Loop model (OpenClaw cron payload, simplified: every | daily | once)

enum LoopSchedule: Codable, Equatable {
    case everyMinutes(Int)
    case dailyAt(hour: Int, minute: Int)
    case once(Date)

    var displayName: String {
        switch self {
        case .everyMinutes(let m):
            if m % 60 == 0 { return m == 60 ? "every hour" : "every \(m / 60)h" }
            return "every \(m)m"
        case .dailyAt(let h, let m):
            return String(format: "daily at %02d:%02d", h, m)
        case .once(let date):
            let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
            return "once at \(f.string(from: date))"
        }
    }
}

struct MaxLoop: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var prompt: String
    var schedule: LoopSchedule
    var enabled: Bool = true
    var createdAt: Date = Date()
    var lastRunAt: Date?
    var lastSummary: String?
    var lastWasError: Bool = false

    var nextRun: Date? {
        guard enabled else { return nil }
        switch schedule {
        case .everyMinutes(let minutes):
            let base = lastRunAt ?? createdAt
            return base.addingTimeInterval(TimeInterval(minutes * 60))
        case .dailyAt(let hour, let minute):
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = hour
            components.minute = minute
            guard let today = Calendar.current.date(from: components) else { return nil }
            if let last = lastRunAt, Calendar.current.isDateInToday(last), last >= today {
                return Calendar.current.date(byAdding: .day, value: 1, to: today)
            }
            return today <= Date() ? today : today
        case .once(let date):
            return lastRunAt == nil ? date : nil
        }
    }

    var isDue: Bool {
        guard enabled, let next = nextRun else { return false }
        return next <= Date()
    }
}

// MARK: - Store

@MainActor
final class LoopStore: ObservableObject {
    static let shared = LoopStore()

    @Published private(set) var loops: [MaxLoop] = []

    private init() { load() }

    func add(_ loop: MaxLoop) {
        loops.append(loop)
        save()
    }

    func update(_ loop: MaxLoop) {
        if let i = loops.firstIndex(where: { $0.id == loop.id }) {
            loops[i] = loop
            save()
        }
    }

    func remove(id: String) {
        loops.removeAll { $0.id == id || $0.name == id }
        save()
    }

    func toggle(id: String) {
        if let i = loops.firstIndex(where: { $0.id == id }) {
            loops[i].enabled.toggle()
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: MaxPaths.loopsFile),
              let decoded = try? JSONDecoder().decode([MaxLoop].self, from: data) else { return }
        loops = decoded
    }

    private func save() {
        MaxPaths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(loops) {
            try? data.write(to: MaxPaths.loopsFile, options: .atomic)
        }
    }
}

// MARK: - Scheduler (timer loop, isolated agent runs — OpenClaw's cron service in miniature)

@MainActor
final class LoopScheduler: ObservableObject {
    static let shared = LoopScheduler()

    @Published private(set) var runningLoopIds: Set<String> = []
    /// The UI observes this to flash the pill's working outline.
    var onActivityChanged: ((Bool) -> Void)?

    private var timer: Timer?

    private init() {}

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func runNow(_ loop: MaxLoop) {
        execute(loop)
    }

    private func tick() {
        for loop in LoopStore.shared.loops where loop.isDue && !runningLoopIds.contains(loop.id) {
            execute(loop)
        }
    }

    private func execute(_ loop: MaxLoop) {
        runningLoopIds.insert(loop.id)
        onActivityChanged?(true)

        // Stamp lastRunAt immediately so a slow run doesn't double-fire.
        var stamped = loop
        stamped.lastRunAt = Date()
        if case .once = loop.schedule { stamped.enabled = false }
        LoopStore.shared.update(stamped)

        Task {
            let session = ChatSession.isolated(prefix: "loop-\(loop.name.prefix(12))")
            let config = MaxConfig.load()
            var finalText = ""
            var failed = false

            let prompt = "Scheduled loop \"\(loop.name)\" fired. Task: \(loop.prompt)"
            for await event in AgentLoop.run(session: session, userText: prompt, config: config, isLoopRun: true) {
                switch event {
                case .turnEnded(let text): finalText = text
                case .failed(let message): finalText = message; failed = true
                default: break
                }
            }

            await MainActor.run {
                var done = LoopStore.shared.loops.first { $0.id == loop.id } ?? stamped
                done.lastRunAt = Date()
                done.lastSummary = String(finalText.prefix(500))
                done.lastWasError = failed
                LoopStore.shared.update(done)

                self.appendLog(loop: loop, text: finalText, failed: failed)

                let silent = finalText.contains("NO_REPLY")
                if !silent || failed {
                    self.notify(
                        title: failed ? "Loop failed: \(loop.name)" : "Max · \(loop.name)",
                        body: String(finalText.replacingOccurrences(of: "NO_REPLY", with: "").prefix(180))
                    )
                }

                self.runningLoopIds.remove(loop.id)
                if self.runningLoopIds.isEmpty { self.onActivityChanged?(false) }
            }
        }
    }

    private func appendLog(loop: MaxLoop, text: String, failed: Bool) {
        let url = MaxPaths.loopLogsDir.appendingPathComponent("\(loop.id).log")
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))]\(failed ? " ERROR" : "") \(text)\n\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "Done." : body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
