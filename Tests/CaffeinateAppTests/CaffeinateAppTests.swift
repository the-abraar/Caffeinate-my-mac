import XCTest
@testable import CaffeinateApp

final class LidControlTests: XCTestCase {
    func testSudoersRulePassesVisudo() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sudoers-\(UUID().uuidString)")
        try LidControl.sudoersContent(user: "blackbird").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = LidControl.run("/usr/sbin/visudo", ["-c", "-f", file.path])
        XCTAssertEqual(r.status, 0, r.output)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(body.components(separatedBy: "NOPASSWD").count - 1, 4)
        XCTAssertFalse(body.contains("*"))
        XCTAssertFalse(LidControl.sudoersPath.split(separator: "/").last!.contains("."))
    }

    func testInstallShellWritesTheExactRule() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sudoers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let r = LidControl.run("/bin/sh", ["-c", LidControl.writeRuleShell(user: "first.last", to: file.path)])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), LidControl.sudoersContent(user: "first.last"))
    }

    func testUsernameAllowlist() {
        XCTAssertTrue(LidControl.isValidUsername("blackbird"))
        XCTAssertTrue(LidControl.isValidUsername("first.last"))
        XCTAssertFalse(LidControl.isValidUsername(""))
        XCTAssertFalse(LidControl.isValidUsername("a b"))
        XCTAssertFalse(LidControl.isValidUsername("x\nALL ALL=(ALL) NOPASSWD: ALL"))
        XCTAssertFalse(LidControl.isValidUsername("-rf"))
    }

    func testParsePmset() {
        let off = "System-wide power settings:\nCurrently in use:\n standby              1\n sleep                1\n"
        let on = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby  1\n"
        XCTAssertFalse(LidControl.parseSleepDisabled(off))
        XCTAssertTrue(LidControl.parseSleepDisabled(on))

        let custom = "Battery Power:\n lowpowermode         1\n sleep 1\nAC Power:\n lowpowermode         0\n"
        XCTAssertEqual(LidControl.parseBatteryLowPowerMode(custom), true)
        XCTAssertEqual(LidControl.parseBatteryLowPowerMode("AC Power:\n lowpowermode 1\n"), nil)
    }

    func testMarkerRoundTrip() {
        let m = LidControl.Marker(prior: false, lowPowerPrior: false, pid: 4242, until: 1_800_000_000)
        XCTAssertEqual(LidControl.Marker(text: m.text), m)
        XCTAssertEqual(LidControl.Marker(text: "prior=1\npid=7\n"), LidControl.Marker(prior: true, pid: 7))
        XCTAssertNil(LidControl.Marker(text: "prior=yes\npid=7\n"))
        XCTAssertNil(LidControl.Marker(text: "prior=0\n"))
    }
}

/// Runs Resources/failsafe.sh against a temp support dir and a fake sudo that logs its arguments.
final class FailsafeScriptTests: XCTestCase {
    private var dir: URL!
    private var log: URL { dir.appendingPathComponent("sudo.log") }
    private var marker: URL { dir.appendingPathComponent("lid-session") }
    private let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/failsafe.sh")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("failsafe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func fakeSudo(exit code: Int) throws -> String {
        let path = dir.appendingPathComponent("sudo").path
        try "#!/bin/sh\necho \"$*\" >> '\(log.path)'\nexit \(code)\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    /// Prints `pmset -g batt` output, so the result doesn't depend on this Mac's battery.
    private func fakePmset(_ source: String, _ percent: Int) throws -> String {
        let path = dir.appendingPathComponent("pmset").path
        let out = "Now drawing from '\(source)'\n -InternalBattery-0 (id=1)\t\(percent)%; discharging; 0:20 remaining present: true"
        try "#!/bin/sh\nprintf '%s\\n' \"\(out)\"\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    @discardableResult
    private func runScript(sudoExit: Int = 0, battery: (String, Int) = ("AC Power", 100)) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.environment = ["HOME": dir.path, "CAFFEINATE_SUPPORT_DIR": dir.path, "CAFFEINATE_SUDO": try fakeSudo(exit: sudoExit),
                         "CAFFEINATE_PMSET": try fakePmset(battery.0, battery.1)]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A live process whose executable is named Caffeinate.
    private func fakeApp() throws -> Process {
        let exe = dir.appendingPathComponent("Caffeinate")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: exe)
        // A copied platform binary is SIGKILLed within a second; an ad-hoc signature keeps it alive.
        XCTAssertEqual(LidControl.run("/usr/bin/codesign", ["-f", "-s", "-", exe.path]).status, 0)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func testNoMarkerDoesNothing() throws {
        XCTAssertEqual(try runScript(), 0)
        XCTAssertEqual(calls, [])
    }

    func testDeadAppRestoresSleepAndLowPowerMode() throws {
        try "prior=0\nlpm=0\npid=999999\n".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertEqual(try runScript(), 0)
        XCTAssertEqual(calls, ["-n /usr/bin/pmset -a disablesleep 0", "-n /usr/bin/pmset -b lowpowermode 0"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReusedPidOfAnotherProcessStillRestores() throws {
        try "prior=1\npid=\(getpid())\n".write(to: marker, atomically: true, encoding: .utf8)
        try runScript()
        XCTAssertEqual(calls, ["-n /usr/bin/pmset -a disablesleep 1"])
    }

    func testLiveAppBeforeDeadlineIsLeftAlone() throws {
        let app = try fakeApp()
        defer { app.terminate() }
        let until = Int(Date().timeIntervalSince1970) + 600
        try "prior=0\npid=\(app.processIdentifier)\nuntil=\(until)\n".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertEqual(try runScript(), 0)
        XCTAssertEqual(calls, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLiveAppPastDeadlineIsTreatedAsHung() throws {
        let app = try fakeApp()
        defer { app.terminate() }
        let until = Int(Date().timeIntervalSince1970) - 1
        try "prior=0\npid=\(app.processIdentifier)\nuntil=\(until)\n".write(to: marker, atomically: true, encoding: .utf8)
        try runScript()
        XCTAssertEqual(calls, ["-n /usr/bin/pmset -a disablesleep 0"])
    }

    /// B5: a hung app never reaches its 15% stop, and disablesleep has turned off low-battery sleep.
    func testLiveAppOnLowBatteryIsRestored() throws {
        let app = try fakeApp()
        defer { app.terminate() }
        let until = Int(Date().timeIntervalSince1970) + 600
        try "prior=0\nlpm=0\npid=\(app.processIdentifier)\nuntil=\(until)\n".write(to: marker, atomically: true, encoding: .utf8)
        try runScript(battery: ("Battery Power", 11))
        XCTAssertEqual(calls, [])
        try runScript(battery: ("AC Power", 5))
        XCTAssertEqual(calls, [])
        try runScript(battery: ("Battery Power", 10))
        XCTAssertEqual(calls, ["-n /usr/bin/pmset -a disablesleep 0", "-n /usr/bin/pmset -b lowpowermode 0"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// B3: a failed restore rewrites the marker with until = now (LidControl.restore), and the
    /// failsafe must then act on it at once, although the app is still running.
    func testLiveAppWithDeadlineNowIsRestored() throws {
        let app = try fakeApp()
        defer { app.terminate() }
        let now = Int(Date().timeIntervalSince1970)
        try LidControl.Marker(prior: false, pid: app.processIdentifier, until: now).text
            .write(to: marker, atomically: true, encoding: .utf8)
        try runScript()
        XCTAssertEqual(calls, ["-n /usr/bin/pmset -a disablesleep 0"])
    }

    func testGarbagePriorRestoresNormalSleep() throws {
        try "prior=;rm -rf /\npid=abc\n".write(to: marker, atomically: true, encoding: .utf8)
        try runScript()
        XCTAssertEqual(calls, ["-n /usr/bin/pmset -a disablesleep 0"])
    }

    func testSudoFailureKeepsMarkerForRetry() throws {
        try "prior=0\npid=999999\n".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertEqual(try runScript(sudoExit: 1), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

final class CLITests: XCTestCase {
    private let cli = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/caffeinate-my-mac")

    private func run(_ args: [String], open: String = "echo", home: String = NSTemporaryDirectory(),
                     stderr: Pipe = Pipe()) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [cli.path] + args
        p.environment = ["CAFFEINATE_OPEN": open, "HOME": home, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = stderr
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testCommandsBuildURLs() throws {
        XCTAssertEqual(try run(["for", "45m", "--lid"]).1, "caffeinate-my-mac://start?minutes=45&lid=1")
        XCTAssertEqual(try run(["for", "2h"]).1, "caffeinate-my-mac://start?minutes=120&lid=0")
        XCTAssertEqual(try run(["until", "9:30"]).1, "caffeinate-my-mac://start?until=9:30&lid=0")
        XCTAssertEqual(try run(["--lid", "idle"]).1, "caffeinate-my-mac://idle?lid=1")
        XCTAssertEqual(try run(["while", "123"]).1, "caffeinate-my-mac://while?pid=123&lid=0")
        XCTAssertEqual(try run(["extend"]).1, "caffeinate-my-mac://extend?minutes=15")
        XCTAssertEqual(try run(["off"]).1, "caffeinate-my-mac://stop")
    }

    /// A fake opener plays the app: it answers in state.plist the way publishState(refusalReason:) does,
    /// echoing the URL's request id. `staleFirst` first writes an accepted answer with no id, like a
    /// running session ending just before the app handles the URL.
    private func answering(refused: Bool, staleFirst: Bool = false) throws -> (open: String, home: String) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("Library/Application Support/Caffeinate")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let opener = home.appendingPathComponent("open.sh")
        let plist = "<plist version=\"1.0\"><dict><key>refused</key><\(refused)/>"
            + "<key>refusalReason</key><string>Lid mode is not set up</string>"
            + "<key>request</key><string>'\"${1##*req=}\"'</string></dict></plist>"
        let stale = "<plist version=\"1.0\"><dict><key>refused</key><false/></dict></plist>"
        let file = "\"$HOME/Library/Application Support/Caffeinate/state.plist\""
        let answer = "printf '%s' '\(plist)' > \(file)"
        let script = staleFirst ? "printf '%s' '\(stale)' > \(file)\n(sleep 0.5; \(answer)) &" : answer
        try "#!/bin/sh\n\(script)\n"
            .write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        return (opener.path, home.path)
    }

    func testRefusedStartExitsNonZeroWithTheReason() throws {
        let fake = try answering(refused: true)
        let err = Pipe()
        XCTAssertEqual(try run(["for", "45m", "--lid"], open: fake.open, home: fake.home, stderr: err).0, 1)
        XCTAssertTrue(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .contains("Lid mode is not set up"))
    }

    func testAcceptedStartExitsZero() throws {
        let fake = try answering(refused: false)
        XCTAssertEqual(try run(["for", "45m"], open: fake.open, home: fake.home).0, 0)
    }

    func testAnswerForAnotherRequestIsIgnored() throws {
        let fake = try answering(refused: true, staleFirst: true)
        XCTAssertEqual(try run(["for", "45m", "--lid"], open: fake.open, home: fake.home).0, 1)
    }

    func testOpenFailureExitsThree() throws {
        XCTAssertEqual(try run(["for", "45m"], open: "/usr/bin/false").0, 3)
        XCTAssertEqual(try run(["off"], open: "/usr/bin/false").0, 3)
    }

    func testNoAnswerExitsThree() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        let err = Pipe()
        XCTAssertEqual(try run(["for", "45m"], open: "/usr/bin/true", home: home.path, stderr: err).0, 3)
        XCTAssertTrue(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .contains("No answer"))
    }

    /// B9: after a crash, state.plist still shows the last session; `status` must not report it.
    func testStatusChecksTheAppIsAlive() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("Library/Application Support/Caffeinate")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let state = dir.appendingPathComponent("state.plist")
        func write(pid: Int32) throws {
            try (["pid": pid, "end": Date().timeIntervalSince1970 + 600, "refused": false] as NSDictionary).write(to: state)
        }

        try write(pid: 999_999)
        let err = Pipe()
        XCTAssertEqual(try run(["status", "--json"], home: home.path, stderr: err).0, 1)
        XCTAssertTrue(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("not running"))

        try write(pid: getpid())  // alive, but not Caffeinate (a reused pid)
        XCTAssertEqual(try run(["status"], home: home.path).0, 1)

        let exe = home.appendingPathComponent("Caffeinate")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: exe)
        XCTAssertEqual(LidControl.run("/usr/bin/codesign", ["-f", "-s", "-", exe.path]).status, 0)
        let app = Process()
        app.executableURL = exe
        app.arguments = ["30"]
        try app.run()
        defer { app.terminate() }
        try write(pid: app.processIdentifier)
        let (code, out) = try run(["status", "--json"], home: home.path)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("\"end\""), out)
    }

    func testBadInputFails() throws {
        XCTAssertEqual(try run(["for", "soon"]).0, 2)
        XCTAssertEqual(try run(["until", "9pm"]).0, 2)
        XCTAssertEqual(try run(["while", "x"]).0, 2)
        XCTAssertEqual(try run([]).0, 2)
    }
}

final class LogicTests: XCTestCase {
    func testAgentTreeCPU() {
        let ps = """
          1     0   0.0 /sbin/launchd
        100     1   1.0 /Users/me/.local/bin/claude
        101   100  30.0 /bin/zsh
        102   101  12.5 /Applications/Some App.app/Contents/MacOS/Some App
        103   100   0.5 claude
        200     1  50.0 /usr/bin/python3
        300     1   2.0 codex
        301   300   4.0 node
        """
        XCTAssertEqual(AgentWatcher.agentTreeCPU(psOutput: ps), 1.0 + 30.0 + 12.5 + 0.5 + 2.0 + 4.0, accuracy: 0.001)
        XCTAssertEqual(AgentWatcher.agentTreeCPU(psOutput: "  1 0 99.0 /Applications/Claude.app/Contents/MacOS/Claude"), 0)
    }

    func testURLCommands() {
        func parse(_ s: String) -> URLCommand? { URLCommand.parse(URL(string: s)!) }
        XCTAssertEqual(parse("caffeinate-my-mac://start?minutes=45&lid=1"), .start(seconds: 2700, lid: true))
        XCTAssertEqual(parse("caffeinate-my-mac://start?minutes=30"), .start(seconds: 1800, lid: false))
        XCTAssertNil(parse("caffeinate-my-mac://start?minutes=0"))
        XCTAssertNil(parse("caffeinate-my-mac://start?minutes=99999"))
        XCTAssertNil(parse("caffeinate-my-mac://start?until=25:00"))
        XCTAssertEqual(parse("caffeinate-my-mac://commute"), .commute)
        XCTAssertEqual(parse("caffeinate-my-mac://idle?lid=1"), .untilIdle(lid: true))
        XCTAssertEqual(parse("caffeinate-my-mac://while?pid=123"), .whilePID(123, lid: false))
        XCTAssertNil(parse("caffeinate-my-mac://while?pid=1"))
        XCTAssertEqual(parse("caffeinate-my-mac://extend"), .extend(seconds: 900))
        XCTAssertNil(parse("caffeinate-my-mac://extend?minutes=-5"))
        XCTAssertEqual(parse("caffeinate-my-mac://stop"), .stop)
        XCTAssertNil(parse("other://stop"))
        XCTAssertNil(parse("caffeinate-my-mac://format-disk"))
    }

    func testSecondsUntil() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 8, minute: 0))!
        XCTAssertEqual(secondsUntil(hour: 8, minute: 30, from: now, calendar: cal), 1800)
        XCTAssertEqual(secondsUntil(hour: 7, minute: 0, from: now, calendar: cal), 23 * 3600)
        XCTAssertNil(secondsUntil(hour: 24, minute: 0, from: now, calendar: cal))
    }

    func testBatteryEstimate() {
        let b = PowerInfo.Battery(percent: 73, onBattery: true, minutesLeft: 107)
        XCTAssertEqual(PowerInfo.estimatedUse(seconds: 45 * 60, battery: b), 31)
        XCTAssertEqual(PowerInfo.estimatedUse(seconds: 10 * 3600, battery: b), 73)
        XCTAssertNil(PowerInfo.estimatedUse(seconds: 60, battery: .init(percent: 80, onBattery: false, minutesLeft: nil)))
    }

    func testHotspotDetection() {
        XCTAssertTrue(NetworkWatcher.isHotspot(online: true, expensive: true, gateways: []))
        XCTAssertTrue(NetworkWatcher.isHotspot(online: true, expensive: false, gateways: ["172.20.10.1"]))
        XCTAssertFalse(NetworkWatcher.isHotspot(online: true, expensive: false, gateways: ["192.168.1.1"]))
        XCTAssertFalse(NetworkWatcher.isHotspot(online: false, expensive: true, gateways: ["172.20.10.1"]))
    }

    func testNtfyTopic() {
        XCTAssertTrue(Notifier.isValidTopic("abraar-commute_1"))
        XCTAssertFalse(Notifier.isValidTopic(""))
        XCTAssertFalse(Notifier.isValidTopic("../admin"))
        XCTAssertFalse(Notifier.isValidTopic("a?b=c"))
    }

    func testHistoryLine() {
        var cal = Calendar.current
        cal.timeZone = .current
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 8, minute: 12))!
        let r = SessionRecord(start: start, minutes: 31, lid: true, batteryUsed: 9, peakThermal: 1,
                              offlineSeconds: 75, reason: "Agents idle")
        // The date follows the user's locale (12 or 24 hour clock), so only the rest is fixed.
        XCTAssertEqual(r.line, SessionRecord.clock.string(from: start) + " · 31m · lid · −9% · warm · offline 1m · Agents idle")
        let gb = DateFormatter()
        gb.locale = Locale(identifier: "en_GB")
        gb.setLocalizedDateFormatFromTemplate("dMMMjmm")
        let us = DateFormatter()
        us.locale = Locale(identifier: "en_US")
        us.setLocalizedDateFormatFromTemplate("dMMMjmm")
        XCTAssertTrue(gb.string(from: start).contains("08:12"), gb.string(from: start))
        XCTAssertTrue(us.string(from: start).contains("8:12") && us.string(from: start).hasSuffix("AM"), us.string(from: start))
    }
}

/// Stands in for sudo, pmset and IOKit, so manager tests never touch this Mac's power settings.
final class FakePower: PowerControl {
    var ready = true
    var beginOK = true
    var endOK = true
    var batteryReading: PowerInfo.Battery? = .init(percent: 80, onBattery: false, minutesLeft: nil)
    var thermal = 0
    private(set) var calls: [String] = []

    func isReady() -> Bool { calls.append("isReady"); return ready }
    func begin(until: Date) -> Bool { calls.append("begin"); return beginOK }
    func end() -> Bool { calls.append("end"); return endOK }
    func upkeep(force: Bool, until: Date) { calls.append("upkeep") }
    func battery() -> PowerInfo.Battery? { batteryReading }
    func isLidClosed() -> Bool { false }  // never true: a closed lid would run pmset sleepnow / displaysleepnow
    func thermalState() -> Int { thermal }
}

final class CaffeinateManagerTests: XCTestCase {
    private var dir: URL!
    private var power: FakePower!
    private var manager: CaffeinateManager!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("manager-\(UUID().uuidString)")
        power = FakePower()
        manager = CaffeinateManager(power: power, dir: dir)
    }

    override func tearDown() {
        manager.stop()  // also stops the real /usr/bin/caffeinate child
        UserDefaults.standard.removeObject(forKey: "agentIdleMinutes")
        try? FileManager.default.removeItem(at: dir)
    }

    private var state: NSDictionary? { NSDictionary(contentsOf: dir.appendingPathComponent("state.plist")) }

    func testLidSessionBeginsAndStopRestores() {
        manager.lidReady = true
        manager.commute()
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.lidMode)
        XCTAssertEqual(manager.totalSeconds, CaffeinateManager.commuteSeconds)
        manager.stop()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(power.calls, ["begin", "end"])
        XCTAssertEqual(manager.history.first?.reason, "Stopped")
    }

    /// B2: a cold-launched app handles the CLI's URL before its async setup check has finished.
    func testColdStartLidURLChecksSetupItself() {
        XCTAssertFalse(manager.lidReady)
        manager.handle(URL(string: "caffeinate-my-mac://start?minutes=45&lid=1&req=r1")!)
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.lidMode)
        XCTAssertEqual(state?["request"] as? String, "r1")
        XCTAssertEqual(state?["refused"] as? Bool, false)
    }

    /// B3: a failed restore says so (LidControl.restore hands the marker to the failsafe).
    func testFailedRestoreIsReported() {
        manager.lidReady = true
        manager.commute()
        power.endOK = false
        manager.stop()
        XCTAssertFalse(manager.isActive)
        XCTAssertTrue(manager.lastSessionSummary.contains("Couldn't restore lid sleep"), manager.lastSessionSummary)
    }

    /// B4: chaining lid sessions (commute every 45 min) must not push the 2 h cap forward.
    func testChainedLidSessionsShareOneCap() {
        manager.lidReady = true
        manager.commute()
        manager.lidStart = Date().addingTimeInterval(-110 * 60)  // 1 h 50 min into the lid stretch
        manager.commute()
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(Double(manager.totalSeconds), 600, accuracy: 2)
        manager.extend(seconds: 15 * 60)
        XCTAssertEqual(Double(manager.totalSeconds), 600, accuracy: 2)
        XCTAssertEqual(power.calls.filter { $0 == "end" }, [], "sleep must stay disabled between them")

        manager.lidStart = Date().addingTimeInterval(-121 * 60)
        manager.commute()
        XCTAssertEqual(state?["refusalReason"] as? String, "Lid sessions stop after 2 h")
        XCTAssertTrue(manager.isActive, "a refused request leaves the running session alone")

        manager.stop()
        manager.commute()  // a fresh stretch after sleep was restored
        XCTAssertEqual(manager.totalSeconds, CaffeinateManager.commuteSeconds)
    }

    /// B8: `while <pid>` on a process that quits just after the check ends the session inside
    /// handle(). That race isn't reproducible here, so this drives the same path (finish() during a
    /// request) through stop: the write must still carry refused=false, or the CLI waits and exits 3.
    func testSessionEndingInsideARequestStillAnswers() {
        manager.start(seconds: 600)
        manager.handle(URL(string: "caffeinate-my-mac://stop?req=r3")!)
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(state?["request"] as? String, "r3")
        XCTAssertEqual(state?["refused"] as? Bool, false)
        XCTAssertEqual((state?["pid"] as? NSNumber)?.int32Value, getpid())
    }

    /// B10: after a sleep, caffeinate's uptime-based -t timer is still running past endDate.
    func testTimerEndsOnTheWallClock() {
        manager.start(seconds: 600)
        manager.endDate = Date().addingTimeInterval(-1)  // as if the Mac slept through the end
        manager.tick()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.history.first?.reason, "Completed")
    }

    func testLidURLRefusedWhenSetupIsMissing() {
        power.ready = false
        manager.handle(URL(string: "caffeinate-my-mac://commute?req=r2")!)
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(state?["refused"] as? Bool, true)
        XCTAssertEqual(state?["refusalReason"] as? String, "Set up lid mode first (Settings)")
        XCTAssertFalse(power.calls.contains("begin"))
    }

    /// Acceptance test 5 in code: the safety stops end a lid session and restore sleep.
    func testBatteryFloorStopsALidSession() {
        manager.lidReady = true
        manager.commute()
        power.batteryReading = .init(percent: 15, onBattery: true, minutesLeft: 40)
        for _ in 0..<30 { manager.tick() }  // the 30 s poll
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(power.calls, ["begin", "end"])
        XCTAssertEqual(manager.history.first?.reason, "Stopped: battery at 15%")
    }

    func testHeatStopsALidSession() {
        manager.lidReady = true
        manager.commute()
        power.thermal = ProcessInfo.ThermalState.serious.rawValue
        for _ in 0..<30 { manager.tick() }
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(power.calls, ["begin", "end"])
        XCTAssertEqual(manager.history.first?.reason, "Stopped: Mac got too hot")
        XCTAssertEqual(manager.history.first?.peakThermal, 2)
        manager.commute()
        XCTAssertEqual(state?["refusalReason"] as? String, "Mac is too hot for lid mode")
    }

    /// Phase 2: "until agents idle" ends after the configured idle minutes, not before.
    func testAgentSessionEndsAfterTheIdleSetting() {
        manager.agentIdleMinutes = 10
        manager.start(seconds: 0, ending: .agentsIdle)
        manager.startDate = Date().addingTimeInterval(-6 * 60)  // no agent activity for 6 min
        manager.tick()
        XCTAssertTrue(manager.isActive)
        manager.agentIdleMinutes = 5
        manager.tick()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.history.first?.reason, "Agents idle")
    }

    /// Phase 3: each dropout shows in the session summary with its time.
    func testOfflineText() {
        let t0 = Date(timeIntervalSince1970: 0)
        let time: (Date) -> String = { "T\(Int($0.timeIntervalSince1970))" }
        XCTAssertNil(CaffeinateManager.offlineText([], time: time))
        XCTAssertNil(CaffeinateManager.offlineText([(t0, 0)], time: time))
        XCTAssertEqual(CaffeinateManager.offlineText([(t0, 130), (t0.addingTimeInterval(500), 30), (t0, 120)], time: time),
                       "offline 2m10s at T0, 30s at T500, 2m at T0")
    }
}
