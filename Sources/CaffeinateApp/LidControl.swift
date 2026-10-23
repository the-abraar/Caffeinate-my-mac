import Foundation

/// Lid-closed awake. Only `pmset -a disablesleep 1` keeps a MacBook running with the lid closed
/// on battery. It needs root, it is system-wide and it survives reboots, so:
/// - a sudoers rule allows exactly four pmset command lines, so sessions never prompt;
/// - every session writes a marker holding the values to restore;
/// - a LaunchAgent (failsafe.sh) restores them if the app dies mid-session.
enum LidControl {
    static let sudoersPath = "/etc/sudoers.d/caffeinate-my-mac"  // no "." in the name: sudo skips such files
    static let pmset = "/usr/bin/pmset"
    static let commands = [
        ["-a", "disablesleep", "0"], ["-a", "disablesleep", "1"],
        ["-b", "lowpowermode", "0"], ["-b", "lowpowermode", "1"],
    ]
    static let agentLabel = "com.abraar.caffeinateapp.failsafe"

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Caffeinate")
    static let markerURL = supportDir.appendingPathComponent("lid-session")
    static let failsafeURL = supportDir.appendingPathComponent("failsafe.sh")
    static let agentPlistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

    // MARK: Setup

    /// True when every pmset command runs without a password and the failsafe agent is installed.
    static func isReady() -> Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
            && commands.allSatisfy { run("/usr/bin/sudo", ["-n", "-l", pmset] + $0).status == 0 }
    }

    static func sudoersContent(user: String) -> String {
        "# Caffeinate.app: lid-closed sessions. Remove this file (or use Revoke in the app) to undo.\n"
            + commands.map { "\(user) ALL=(root:wheel) NOPASSWD: \(pmset) \($0.joined(separator: " "))\n" }.joined()
    }

    /// The username is spliced into a sudoers file, so allow only plain short-name characters.
    static func isValidUsername(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil
    }

    /// One admin prompt: the root shell writes the rule to a root-owned staging file, visudo checks
    /// that file, and it is moved into place 0440. No user-writable copy exists for another process
    /// to swap between the check and the install.
    /// Returns an error message, or nil on success. Blocks, so call it off the main thread.
    static func install() -> String? {
        let user = NSUserName()
        guard isValidUsername(user) else { return "Unsupported username: \(user)" }
        let staged = sudoersPath + ".new"  // has a ".", so sudo ignores it until the mv
        if let error = runAdmin(
            "umask 077; /bin/rm -f \(staged) && \(writeRuleShell(user: user, to: staged))"
                + " && /usr/sbin/visudo -c -f \(staged) && /usr/sbin/chown root:wheel \(staged)"
                + " && /bin/chmod 440 \(staged) && /bin/mv -f \(staged) \(sudoersPath)"
                + " || { /bin/rm -f \(staged); false; }",
            prompt: "Caffeinate needs your password once to keep your Mac awake with the lid closed."
        ) { return error }
        return installFailsafe()
    }

    /// Shell that writes `sudoersContent(user:)` to `path`. Each line is single-quoted, which is safe
    /// because the content has no quotes (the username passed `isValidUsername`).
    static func writeRuleShell(user: String, to path: String) -> String {
        let lines = sudoersContent(user: user).split(separator: "\n").map { "'\($0)'" }.joined(separator: " ")
        return "/usr/bin/printf '%s\\n' \(lines) > \(path)"
    }

    /// Removes the failsafe and the sudoers rule. If a session's marker is still there, the same
    /// admin shell puts sleep back first, so revoking never strands disablesleep on.
    static func revoke() -> String? {
        var shell = "/bin/rm -f \(sudoersPath)"
        if let m = readMarker() {
            shell = "\(pmset) -a disablesleep \(m.prior ? 1 : 0); " + shell
            if let lpm = m.lowPowerPrior { shell = "\(pmset) -b lowpowermode \(lpm ? 1 : 0); " + shell }
        }
        if let error = runAdmin(shell, prompt: "Caffeinate needs your password to remove lid-closed access.") {
            return error
        }
        removeMarker()
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: agentPlistURL)
        try? FileManager.default.removeItem(at: failsafeURL)
        return nil
    }

    /// Copies failsafe.sh out of the bundle (so moving the app can't break it) and loads the agent.
    static func installFailsafe() -> String? {
        guard let script = Bundle.main.url(forResource: "failsafe", withExtension: "sh") else {
            return "failsafe.sh is missing from the app bundle. Rebuild with ./build.sh."
        }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/bin/sh", failsafeURL.path],
            "EnvironmentVariables": ["CAFFEINATE_SUPPORT_DIR": supportDir.path],
            "StartInterval": 30,
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: failsafeURL)
            try FileManager.default.copyItem(at: script, to: failsafeURL)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: agentPlistURL)
        } catch {
            return "Could not install the failsafe: \(error.localizedDescription)"
        }
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        let load = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlistURL.path])
        return load.status == 0 ? nil : "Could not load the failsafe agent: \(load.output)"
    }

    /// Setup copies failsafe.sh once, so replace an older copy at launch: fixes to it must reach
    /// Macs that were set up before. Atomic, so a failsafe run never sees a half-written script.
    static func refreshFailsafeScript() {
        guard let script = Bundle.main.url(forResource: "failsafe", withExtension: "sh"),
              let new = try? Data(contentsOf: script), let old = try? Data(contentsOf: failsafeURL),
              new != old else { return }
        try? new.write(to: failsafeURL, options: .atomic)
    }

    // MARK: Session

    struct Marker: Equatable {
        var prior: Bool            // SleepDisabled before the session
        var lowPowerPrior: Bool?   // battery Low Power Mode before, nil when we left it alone
        var pid: Int32
        var until: Int?            // epoch seconds; past this the failsafe restores even if the app still runs

        var text: String {
            "prior=\(prior ? 1 : 0)\n" + (lowPowerPrior.map { "lpm=\($0 ? 1 : 0)\n" } ?? "")
                + "pid=\(pid)\n" + (until.map { "until=\($0)\n" } ?? "")
        }

        init(prior: Bool, lowPowerPrior: Bool? = nil, pid: Int32 = getpid(), until: Int? = nil) {
            self.prior = prior
            self.lowPowerPrior = lowPowerPrior
            self.pid = pid
            self.until = until
        }

        init?(text: String) {
            var values: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = parts[1] }
            }
            guard let prior = values["prior"], prior == "0" || prior == "1",
                  let pid = values["pid"].flatMap(Int32.init) else { return nil }
            self.init(prior: prior == "1", lowPowerPrior: values["lpm"].map { $0 == "1" }, pid: pid,
                      until: values["until"].flatMap(Int.init))
        }
    }

    static func readMarker() -> Marker? {
        (try? String(contentsOf: markerURL, encoding: .utf8)).flatMap(Marker.init(text:))
    }

    static func writeMarker(_ m: Marker) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? m.text.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    static func removeMarker() { try? FileManager.default.removeItem(at: markerURL) }

    /// The running session's marker, so upkeep can put back exactly what begin wrote.
    private static var sessionMarker: Marker?

    /// Turns lid-closed awake on and battery Low Power Mode on (less heat in a bag).
    /// An existing marker means an earlier session never restored, so its saved values win.
    static func begin(until: Date) -> Bool {
        let existing = readMarker()
        let lpm = existing?.lowPowerPrior ?? (batteryLowPowerMode() == false ? false : nil)
        let marker = Marker(prior: existing?.prior ?? (sleepDisabled() ?? false), lowPowerPrior: lpm,
                            until: Int(until.timeIntervalSince1970))
        writeMarker(marker)  // before pmset, so a crash in between is still restored
        sessionMarker = marker
        guard setSleepDisabled(true) else {
            restore(marker)
            return false
        }
        if lpm != nil { setBatteryLowPowerMode(true) }
        return true
    }

    /// Keeps the marker in place (the failsafe may have removed it) and SleepDisabled on.
    /// `force` re-applies even if pmset already reads 1: Apple Silicon can drop closed-display
    /// mode after a power-source change while the value still reads 1.
    static func upkeep(force: Bool, until: Date) {
        if readMarker() == nil {
            // The failsafe restored early (the app looked hung) and deleted it: set the session up again
            // with the original values. Without them the prior is unknown, and "sleep allowed" is the safe side.
            var m = sessionMarker ?? Marker(prior: false)
            m.until = Int(until.timeIntervalSince1970)
            writeMarker(m)
            if m.lowPowerPrior != nil { setBatteryLowPowerMode(true) }
        }
        if force || sleepDisabled() != true { setSleepDisabled(true) }
    }

    /// Ends a session. Without a marker the prior is unknown, so sleep is allowed again.
    @discardableResult
    static func end() -> Bool { restore(readMarker() ?? Marker(prior: false)) }

    /// Puts sleep and Low Power Mode back. If sudo refused, the marker stays with its deadline set
    /// to now: the failsafe skips a live app until the deadline, and would otherwise wait up to 2 h.
    @discardableResult
    static func restore(_ m: Marker) -> Bool {
        var ok = setSleepDisabled(m.prior)
        if let lpm = m.lowPowerPrior { ok = setBatteryLowPowerMode(lpm) && ok }
        if ok {
            removeMarker()
        } else {
            var due = m
            due.until = Int(Date().timeIntervalSince1970)
            writeMarker(due)
        }
        return ok
    }

    // MARK: pmset

    static func sleepDisabled() -> Bool? {
        let r = run(pmset, ["-g"])
        return r.status == 0 ? parseSleepDisabled(r.output) : nil
    }

    /// `pmset -g` lists SleepDisabled only while it is set.
    static func parseSleepDisabled(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count >= 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }

    static func batteryLowPowerMode() -> Bool? {
        let r = run(pmset, ["-g", "custom"])
        return r.status == 0 ? parseBatteryLowPowerMode(r.output) : nil
    }

    static func parseBatteryLowPowerMode(_ output: String) -> Bool? {
        var inBattery = false
        for line in output.split(separator: "\n") {
            if !line.hasPrefix(" ") { inBattery = line.hasPrefix("Battery Power"); continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if inBattery, parts.count >= 2, parts[0] == "lowpowermode" { return parts[1] == "1" }
        }
        return nil
    }

    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]).status == 0
    }

    @discardableResult
    static func setBatteryLowPowerMode(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", pmset, "-b", "lowpowermode", on ? "1" : "0"]).status == 0
    }

    // MARK: Processes

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // drain before waiting, or a full pipe deadlocks
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs a fixed shell string as root through the standard macOS admin password dialog.
    private static func runAdmin(_ shell: String, prompt: String) -> String? {
        func quote(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let r = run("/usr/bin/osascript", [
            "-e", "do shell script \"\(quote(shell))\" with prompt \"\(quote(prompt))\" with administrator privileges",
        ])
        if r.status == 0 { return nil }
        return r.output.contains("-128") ? "Cancelled" : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What a session needs from the system. CaffeinateManager takes it as a parameter, so tests can
/// drive the state machine without sudo, pmset or real lid and battery readings.
protocol PowerControl {
    func isReady() -> Bool
    func begin(until: Date) -> Bool
    func end() -> Bool
    func upkeep(force: Bool, until: Date)
    func battery() -> PowerInfo.Battery?
    func isLidClosed() -> Bool
    func thermalState() -> Int  // ProcessInfo.ThermalState raw value
}

struct SystemPower: PowerControl {
    func isReady() -> Bool { LidControl.isReady() }
    func begin(until: Date) -> Bool { LidControl.begin(until: until) }
    func end() -> Bool { LidControl.end() }
    func upkeep(force: Bool, until: Date) { LidControl.upkeep(force: force, until: until) }
    func isLidClosed() -> Bool { PowerInfo.isLidClosed() }

    // Debug hook for acceptance test 5 (fake a battery-floor or heat stop on real hardware):
    //   defaults write com.abraar.caffeinateapp debugBatteryPercent -int 14   (on battery at 14%)
    //   defaults write com.abraar.caffeinateapp debugThermal -int 2           (.serious)
    // The app reads them every 30 s. Undo with `defaults delete com.abraar.caffeinateapp <key>`.
    func battery() -> PowerInfo.Battery? {
        let fake = UserDefaults.standard.integer(forKey: "debugBatteryPercent")
        return fake > 0 ? .init(percent: fake, onBattery: true, minutesLeft: nil) : PowerInfo.battery()
    }

    func thermalState() -> Int {
        max(ProcessInfo.processInfo.thermalState.rawValue, UserDefaults.standard.integer(forKey: "debugThermal"))
    }
}
