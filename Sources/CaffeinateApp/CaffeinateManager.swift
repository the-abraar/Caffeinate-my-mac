import Foundation
import Combine

final class CaffeinateManager: ObservableObject {
    @Published var isActive: Bool = false
    @Published var remainingSeconds: Int = 0
    @Published var totalSeconds: Int = 0
    @Published var shutdownAfter: Bool = false
    @Published var lastSessionSummary: String = "No session yet"

    private var process: Process?
    private var timer: Timer?
    private var endDate: Date?
    private var manualStop: Bool = false

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - (Double(remainingSeconds) / Double(totalSeconds))
    }

    var remainingText: String {
        let h = remainingSeconds / 3600
        let m = (remainingSeconds % 3600) / 60
        let s = remainingSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    func start(durationSeconds: Int, shutdownAfter: Bool) {
        stop(manual: true, quiet: true)

        totalSeconds = durationSeconds
        remainingSeconds = durationSeconds
        endDate = Date().addingTimeInterval(TimeInterval(durationSeconds))
        self.shutdownAfter = shutdownAfter
        manualStop = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d", "-i", "-m", "-s", "-t", "\(durationSeconds)"]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleCompletion()
            }
        }

        do {
            try p.run()
            process = p
            isActive = true
            startTimer()
        } catch {
            lastSessionSummary = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stop(manual: Bool = true, quiet: Bool = false) {
        guard isActive || process != nil else { return }
        manualStop = manual
        timer?.invalidate()
        timer = nil
        process?.terminationHandler = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        isActive = false
        if !quiet {
            lastSessionSummary = "Stopped manually at \(Self.timeFormatter.string(from: Date()))"
        }
        remainingSeconds = 0
        totalSeconds = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func tick() {
        guard let endDate else { return }
        let remaining = Int(ceil(endDate.timeIntervalSinceNow))
        remainingSeconds = max(0, remaining)
        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func handleCompletion() {
        timer?.invalidate()
        timer = nil
        let wasManual = manualStop
        let didShutdown = shutdownAfter
        isActive = false
        process = nil
        remainingSeconds = 0

        if wasManual {
            return
        }

        lastSessionSummary = "Completed at \(Self.timeFormatter.string(from: Date()))"

        if didShutdown {
            triggerShutdown()
        }
    }

    private func triggerShutdown() {
        let script = "tell application \"System Events\" to shut down"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
