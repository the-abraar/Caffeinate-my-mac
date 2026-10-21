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
        XCTAssertEqual(r.line, "15 Oct 08:12 · 31m · lid · −9% · warm · offline 1m · Agents idle")
    }
}

/// Stands in for sudo, pmset and IOKit, so manager tests never touch this Mac's power settings.
final class FakePower: PowerControl {
    var ready = true
    var beginOK = true
    var endOK = true
    var batteryReading: PowerInfo.Battery? = .init(percent: 80, onBattery: false, minutesLeft: nil)
    private(set) var calls: [String] = []

    func isReady() -> Bool { calls.append("isReady"); return ready }
    func begin(until: Date) -> Bool { calls.append("begin"); return beginOK }
    func end() -> Bool { calls.append("end"); return endOK }
    func upkeep(force: Bool, until: Date) { calls.append("upkeep") }
    func battery() -> PowerInfo.Battery? { batteryReading }
    func isLidClosed() -> Bool { false }  // never true: a closed lid would run pmset sleepnow / displaysleepnow
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

    func testLidURLRefusedWhenSetupIsMissing() {
        power.ready = false
        manager.handle(URL(string: "caffeinate-my-mac://commute?req=r2")!)
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(state?["refused"] as? Bool, true)
        XCTAssertEqual(state?["refusalReason"] as? String, "Set up lid mode first (Settings)")
        XCTAssertFalse(power.calls.contains("begin"))
    }
}
