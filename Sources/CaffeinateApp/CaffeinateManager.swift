import Foundation
import Combine
import AppKit
import WidgetKit
import ServiceManagement

final class CaffeinateManager: ObservableObject {
    /// What ends a session besides Stop. Non-timer sessions still stop at a hard cap.
    enum Ending: String { case timer, agentsIdle, processExit }

    static let commuteSeconds = 45 * 60
    static let lidCap = 2 * 3600       // a lid-closed session never runs longer, whatever ends it
    static let idleCap = 12 * 3600     // cap for agent/process sessions without lid mode
    static let agentIdleLimit: TimeInterval = 5 * 60
    static let batteryFloor = 15

    @Published var isActive: Bool = false
    @Published var remainingSeconds: Int = 0
    @Published var totalSeconds: Int = 0
    @Published var shutdownAfter: Bool = false
    @Published var lidMode: Bool = false
    @Published var ending: Ending = .timer
    @Published var waitName: String?
    @Published var lastSessionSummary: String = "No session yet"
    @Published var battery: PowerInfo.Battery?
    @Published var lidReady = false
    @Published var lidBusy = false
    @Published var screenLockImmediate: Bool?
    @Published var onHotspot = false
    @Published var agentsWorking = false
    @Published var history: [SessionRecord]
    @Published var autoCommute = UserDefaults.standard.bool(forKey: "autoCommute") {
        didSet {
            UserDefaults.standard.set(autoCommute, forKey: "autoCommute")
            updateAgentWatching()
        }
    }
    @Published var keepDisplayAwake = UserDefaults.standard.bool(forKey: "keepDisplayAwake") {
        didSet { UserDefaults.standard.set(keepDisplayAwake, forKey: "keepDisplayAwake") }
    }
    @Published var shutdownCountdown: Int? = nil
    private var shutdownTimer: Timer?
    private var shutdownHold: Process?
    @Published var ntfyTopic = UserDefaults.standard.string(forKey: "ntfyTopic") ?? "" {
        didSet { UserDefaults.standard.set(ntfyTopic, forKey: "ntfyTopic") }
    }

    private var process: Process?
    private var timer: Timer?
    private var startDate = Date()
    private var endDate: Date?
    private var batteryAtStart: Int?
    private var peakThermal = 0
    private var offlineSeconds: TimeInterval = 0
    private var offlineSince: Date?
    private var lidWasClosed = false
    private var ticks = 0
    private var waitSource: DispatchSourceProcess?
    private var armedThisConnection = false
    private var request: String?

    private let power: PowerControl
    private let stateURL: URL
    private let historyURL: URL
    private let agents = AgentWatcher()
    private let network = NetworkWatcher()
    private var powerObserver: PowerInfo.Observer?
    private var thermalObserver: NSObjectProtocol?

    private var lidDeadline: Date { startDate.addingTimeInterval(TimeInterval(Self.lidCap)) }

    /// `dir` holds state.plist and history.json; tests pass a temp dir and a fake `power`.
    init(power: PowerControl = SystemPower(), dir: URL = LidControl.supportDir) {
        self.power = power
        stateURL = dir.appendingPathComponent("state.plist")
        historyURL = dir.appendingPathComponent("history.json")
        history = SessionHistory.load(from: historyURL)
        battery = power.battery()
    }

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

    // MARK: Lifecycle

    /// Runs once the single-instance lock is held, so a second copy can never touch lid state.
    func launch() {
        // A marker at launch means the last run died during a lid session.
        if let marker = LidControl.readMarker() {
            lastSessionSummary = LidControl.restore(marker)
                ? "Restored lid sleep after an unexpected quit"
                : "Couldn't restore lid sleep. Run: sudo pmset -a disablesleep 0"
        }
        publishState()  // clears a crashed run's widget state
        Notifier.requestPermission()
        agents.onActivity = { [weak self] in self?.agentActivity() }
        network.onChange = { [weak self] in self?.networkChanged() }
        network.start()
        powerObserver = PowerInfo.Observer { [weak self] in self?.powerChanged() }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.thermalChanged() }
        refreshSetup()
    }

    /// Normal quit, logout or restart: never leave lid sleep disabled.
    func quit() {
        finish("Quit")
    }

    /// sudo and sysadminctl spawn processes, so check off the main thread.
    func refreshSetup() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ready = self.power.isReady()
            let lock = PowerInfo.screenLockIsImmediate()
            DispatchQueue.main.async {
                self.lidReady = ready
                self.screenLockImmediate = lock
            }
        }
    }

    // MARK: Sessions

    func commute() {
        start(seconds: Self.commuteSeconds, lid: true)
    }

    func start(seconds: Int, lid: Bool = false, shutdownAfter: Bool = false,
               ending: Ending = .timer, waitPID: pid_t? = nil) {
        // Refuse before touching the running session, so a bad request doesn't end it.
        if let pid = waitPID, kill(pid, 0) != 0, errno != EPERM {
            return refuse("No running process \(pid)")
        }
        if lid, let problem = lidBlocker() { return refuse(problem) }
        var seconds = ending == .timer ? seconds : (lid ? Self.lidCap : Self.idleCap)
        guard seconds > 0 else { return refuse("Duration must be greater than zero") }
        // Lid to lid keeps sleep disabled throughout: with the lid shut, a gap would sleep the Mac.
        finish(nil, keepLid: lid)

        startDate = Date()
        if lid {
            seconds = min(seconds, Self.lidCap)
            // The failsafe's deadline sits a little past the app's own, so the app normally ends first.
            guard power.begin(until: lidDeadline.addingTimeInterval(120)) else {
                lidReady = false
                return refuse("Lid mode failed: sudo refused. Set it up again in Settings.")
            }
        }
        guard spawnCaffeinate(seconds: seconds, lid: lid) else {
            if lid { _ = power.end() }
            return refuse("Failed to launch caffeinate process")
        }

        totalSeconds = seconds
        remainingSeconds = seconds
        endDate = startDate.addingTimeInterval(TimeInterval(seconds))
        self.shutdownAfter = shutdownAfter && !lid  // a forced shutdown would kill the agents
        lidMode = lid
        self.ending = ending
        batteryAtStart = power.battery()?.percent
        peakThermal = ProcessInfo.processInfo.thermalState.rawValue
        offlineSeconds = 0
        offlineSince = network.isOnline ? nil : Date()
        lidWasClosed = power.isLidClosed()
        ticks = 0
        isActive = true
        startTimer()
        publishState()
        updateAgentWatching()
        if let pid = waitPID { watchExit(of: pid) }  // last: it may finish at once if the process is gone
    }

    func stop() {
        finish("Stopped")
    }

    /// caffeinate can't extend `-t`, so a fresh one replaces it.
    func extend(seconds: Int) {
        guard isActive, ending == .timer, let endDate else { return }
        var newEnd = endDate.addingTimeInterval(TimeInterval(seconds))
        if lidMode { newEnd = min(newEnd, lidDeadline) }
        guard newEnd > endDate else {
            lastSessionSummary = "Lid sessions stop after \(Self.lidCap / 3600) h"
            return
        }
        guard spawnCaffeinate(seconds: Int(ceil(newEnd.timeIntervalSinceNow)), lid: lidMode) else { return }
        totalSeconds += Int(newEnd.timeIntervalSince(endDate))
        self.endDate = newEnd
        tick()
        publishState()
    }

    func handle(_ url: URL) {
        // The CLI's request id, echoed in every state write this URL causes.
        request = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "req" }?.value
        defer { request = nil }
        guard let command = URLCommand.parse(url) else {
            // Not refuse(): any local app can open these, so its text never goes to a notification.
            let reason = "Ignored URL: \(url.absoluteString)"
            lastSessionSummary = reason
            publishState(refusalReason: reason)
            return
        }
        switch command {
        case let .start(seconds, lid): start(seconds: seconds, lid: lid)
        case .commute: commute()
        case let .untilIdle(lid): start(seconds: 0, lid: lid, ending: .agentsIdle)
        case let .whilePID(pid, lid): start(seconds: 0, lid: lid, ending: .processExit, waitPID: pid)
        case let .extend(seconds): extend(seconds: seconds)
        case .stop: stop()
        }
    }

    /// Every refusal is notified: an auto commute or an agent's request that fails quietly lets
    /// the Mac sleep mid-agent once the lid closes.
    private func refuse(_ reason: String) {
        lastSessionSummary = reason
        publishState(refusalReason: reason)
        Notifier.send("Not started: \(reason)", ntfyTopic: ntfyTopic)
    }

    /// Why lid mode can't start right now, or nil.
    private func lidBlocker() -> String? {
        // A URL that cold-launches the app arrives before refreshSetup's async check returns.
        if !lidReady { lidReady = power.isReady() }
        if !lidReady { return "Set up lid mode first (Settings)" }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return "Mac is too hot for lid mode"
        }
        if let b = power.battery(), b.onBattery, b.percent <= Self.batteryFloor {
            return "Battery at \(b.percent)%: too low for lid mode"
        }
        return nil
    }

    /// Starts caffeinate for `seconds`, replacing the running one.
    private func spawnCaffeinate(seconds: Int, lid: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w: caffeinate exits with this app, so a crash leaves no assertion behind.
        // Drop -d by default: display sleep is permitted so screen locks safely when user walks away.
        // Display sleep prevention is opt-in via keepDisplayAwake (never in lid mode).
        let displayArgs = (!lid && keepDisplayAwake) ? ["-d"] : []
        p.arguments = displayArgs + ["-i", "-m", "-s", "-t", "\(seconds)", "-w", "\(getpid())"]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.caffeinateExited() }
        }
        do {
            try p.run()
        } catch {
            lastSessionSummary = "Failed to start: \(error.localizedDescription)"
            return false
        }
        if let old = process {
            old.terminationHandler = nil
            if old.isRunning { old.terminate() }
        }
        process = p
        return true
    }

    private func caffeinateExited() {
        let shutdown = shutdownAfter
        finish(ending == .timer ? "Completed" : "Hit the \((lidMode ? Self.lidCap : Self.idleCap) / 3600) h cap",
               notify: true)
        if shutdown { startShutdownCountdown() }
    }

    /// The session's caffeinate has exited, so hold idle sleep off for the countdown: a sleeping Mac
    /// pauses the Timer and would never shut down.
    func startShutdownCountdown() {
        clearShutdownCountdown()
        shutdownCountdown = 60
        let hold = Process()
        hold.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        hold.arguments = ["-i", "-t", "90", "-w", "\(getpid())"]
        try? hold.run()
        shutdownHold = hold
        Notifier.send("Mac will force-quit all apps and shut down in 60 seconds. Open Caffeinate to cancel.", ntfyTopic: ntfyTopic)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let count = self.shutdownCountdown else { return }
            if count > 1 {
                self.shutdownCountdown = count - 1
            } else {
                self.clearShutdownCountdown()
                self.triggerShutdown()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        shutdownTimer = t
    }

    func cancelShutdownCountdown() {
        clearShutdownCountdown()
        lastSessionSummary = "Auto-shutdown canceled"
    }

    private func clearShutdownCountdown() {
        shutdownTimer?.invalidate()
        shutdownTimer = nil
        shutdownHold?.terminate()
        shutdownHold = nil
        shutdownCountdown = nil
    }

    private func watchExit(of pid: pid_t) {
        waitName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.finish("\(self?.waitName ?? "Process") quit", notify: true)
        }
        source.resume()
        waitSource = source
        if kill(pid, 0) != 0, errno == ESRCH { finish("\(waitName ?? "Process") quit", notify: true) }
    }

    /// Ends the session: stops caffeinate, restores lid sleep, records it.
    /// `reason` nil means a new session is replacing this one; `keepLid` leaves lid sleep
    /// disabled (and the marker with the original values) for that new lid session.
    private func finish(_ reason: String?, notify: Bool = false, keepLid: Bool = false) {
        clearShutdownCountdown()
        guard isActive else { return }
        timer?.invalidate()
        timer = nil
        waitSource?.cancel()
        waitSource = nil
        process?.terminationHandler = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil

        var summary = reason.map { "\($0) at \(Self.clock())" }
        var notify = notify
        if lidMode && !keepLid {
            if !power.end() {
                // Loud on purpose: with disablesleep stuck on, macOS's own low-battery sleep is off too.
                summary = [summary, "Couldn't restore lid sleep. The failsafe retries every 30 s; to fix it now, run: sudo pmset -a disablesleep 0"]
                    .compactMap { $0 }.joined(separator: ". ")
                notify = true
            }
            if power.isLidClosed() { scheduleSleepCheck() }
        }
        if let since = offlineSince {
            offlineSeconds += Date().timeIntervalSince(since)
            offlineSince = nil
        }
        if let reason { record(reason) }

        isActive = false
        lidMode = false
        ending = .timer
        waitName = nil
        remainingSeconds = 0
        totalSeconds = 0
        publishState()
        updateAgentWatching()
        if let summary {
            lastSessionSummary = summary
            if notify { Notifier.send(summary, ntfyTopic: ntfyTopic) }
        }
    }

    /// Sleep comes back with the lid still shut. If the Mac is somehow still up a minute
    /// later, ask it to sleep (pmset sleepnow needs no root).
    private func scheduleSleepCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !isActive, power.isLidClosed() else { return }
            LidControl.run(LidControl.pmset, ["sleepnow"])
        }
    }

    private func record(_ reason: String) {
        let used = batteryAtStart.flatMap { start in power.battery().map { start - $0.percent } }
        let r = SessionRecord(
            start: startDate, minutes: Int(Date().timeIntervalSince(startDate) / 60), lid: lidMode,
            batteryUsed: used, peakThermal: peakThermal, offlineSeconds: Int(offlineSeconds), reason: reason)
        history = Array(([r] + history).prefix(SessionHistory.limit))
        SessionHistory.save(history, to: historyURL)
    }

    // MARK: Ticks and safety

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
        remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        if lidMode {
            // Lock as the lid shuts: display sleep plus "require password immediately".
            let closed = power.isLidClosed()
            if closed && !lidWasClosed { LidControl.run(LidControl.pmset, ["displaysleepnow"]) }
            lidWasClosed = closed
        }
        if ending == .agentsIdle,
           Date().timeIntervalSince(max(startDate, agents.lastActivity ?? startDate)) > Self.agentIdleLimit {
            finish("Agents idle", notify: true)
            return
        }
        ticks += 1
        if ticks % 30 == 0 {
            powerChanged()
            agentsWorking = agents.isWorking
            // On the main thread on purpose: it must never race finish()'s restore.
            if lidMode { power.upkeep(force: false, until: lidDeadline.addingTimeInterval(120)) }
        }
    }

    private func powerChanged() {
        let b = power.battery()
        let sourceChanged = b?.onBattery != battery?.onBattery
        battery = b
        guard lidMode else { return }
        if let b, b.onBattery, b.percent <= Self.batteryFloor {
            finish("Stopped: battery at \(b.percent)%", notify: true)
        } else if sourceChanged {
            // Apple Silicon can drop closed-display mode when the charger is plugged or pulled.
            power.upkeep(force: true, until: lidDeadline.addingTimeInterval(120))
        }
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        peakThermal = max(peakThermal, state.rawValue)
        if lidMode, state.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            finish("Stopped: Mac got too hot", notify: true)
        }
    }

    // MARK: Agents and hotspot

    private func agentActivity() {
        agentsWorking = true
        maybeAutoCommute()
    }

    private func networkChanged() {
        let wasOnHotspot = onHotspot
        onHotspot = network.onHotspot
        if onHotspot && !wasOnHotspot { armedThisConnection = false }
        if isActive {
            if !network.isOnline, offlineSince == nil { offlineSince = Date() }
            if network.isOnline, let since = offlineSince {
                offlineSeconds += Date().timeIntervalSince(since)
                offlineSince = nil
            }
        }
        updateAgentWatching()
        maybeAutoCommute()
    }

    /// Opt-in: on the hotspot with agents working, start lid mode while the lid is still open.
    /// Once the lid shuts without it, the Mac is already asleep. Once per hotspot connection.
    private func maybeAutoCommute() {
        guard autoCommute, onHotspot, lidReady, !isActive, !armedThisConnection, agents.isWorking else { return }
        armedThisConnection = true
        start(seconds: 0, lid: true, ending: .agentsIdle)
        if isActive {
            Notifier.send("Commute mode on: agents are working on the hotspot. You can close the lid.",
                          ntfyTopic: ntfyTopic)
        }
    }

    private func updateAgentWatching() {
        if (autoCommute && onHotspot) || (isActive && ending == .agentsIdle) {
            agents.start()
        } else {
            agents.stop()
        }
        agentsWorking = agents.isWorking
    }

    // MARK: Lid setup

    func setUpLid() {
        lidBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let error = LidControl.install()
            let ready = LidControl.isReady()
            DispatchQueue.main.async {
                self.lidBusy = false
                self.lidReady = ready
                self.lastSessionSummary = error ?? (ready ? "Lid mode is ready" : "Setup ran, but sudo still asks for a password")
            }
        }
    }

    func revokeLid() {
        if lidMode { stop() }
        lidBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let error = LidControl.revoke()
            let ready = LidControl.isReady()
            DispatchQueue.main.async {
                self.lidBusy = false
                self.lidReady = ready
                self.lastSessionSummary = error ?? "Lid mode access removed"
            }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastSessionSummary = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Shutdown

    /// Triggers the macOS Automation prompt for System Events now, so the shutdown
    /// at the end of an unattended session never stops to ask.
    func requestShutdownPermission(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let granted = Self.runSystemEvents("get name")
            DispatchQueue.main.async { completion(granted) }
        }
    }

    private func triggerShutdown() {
        // Forced: quit every app first so none can cancel the shutdown (unsaved work is lost).
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app != .current {
            app.forceTerminate()
        }
        if !Self.runSystemEvents("shut down") {
            lastSessionSummary = "Shutdown failed: allow Caffeinate under Privacy & Security > Automation"
        }
    }

    private static func runSystemEvents(_ command: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to \(command)"]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Widget and CLI state

    /// state.plist is read by the sandboxed widget through a home-relative read-only entitlement
    /// (Widget.entitlements), and by `caffeinate-my-mac status`.
    private func publishState(refusalReason: String? = nil) {
        var state: [String: Any] = [:]
        if isActive, let endDate {
            state = ["end": endDate.timeIntervalSince1970, "total": totalSeconds, "shutdown": shutdownAfter,
                     "lid": lidMode, "ending": ending.rawValue, "refused": false]
        }
        if let refusalReason {
            state["refused"] = true
            state["refusalReason"] = refusalReason
        }
        if let request { state["request"] = request }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (state as NSDictionary).write(to: stateURL)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func clock() -> String { timeFormatter.string(from: Date()) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
