import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: CaffeinateManager

    enum Ends: String, CaseIterable, Identifiable {
        case timer = "After a timer"
        case time = "At a time"
        case agents = "When agents go idle"
        case app = "When an app quits"
        var id: Self { self }
    }

    @State private var hours: Int = 2
    @State private var minutes: Int = 0
    @State private var ends: Ends = .timer
    @State private var untilTime = Date().addingTimeInterval(3600)
    @State private var appPID: pid_t = 0
    @State private var lid: Bool = false
    @State private var shutdownAfter: Bool = false

    private let presets: [(String, Int)] = [
        ("30m", 30 * 60),
        ("1h", 60 * 60),
        ("2h", 2 * 60 * 60),
        ("3h", 3 * 60 * 60)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let count = manager.shutdownCountdown {
                shutdownCountdownBanner(count: count)
            }

            statusCard

            if !manager.isActive {
                configSection
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("SETTINGS & PREFERENCES")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                settings
            }

            Divider()

            if !manager.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSION HISTORY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    historySection
                }
                Divider()
            }

            Text(manager.lastSessionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)  // the app delegate ends the session
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func shutdownCountdownBanner(count: Int) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Auto-Shutting Down in \(count)s")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
            }
            Text("Auto-shutdown will force-quit all applications. Any unsaved files will be lost.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Cancel Shutdown") {
                manager.cancelShutdownCountdown()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
    }

    private var header: some View {
        HStack {
            Image(systemName: manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.title2)
                .foregroundStyle(manager.isActive ? .orange : .secondary)
                .accessibilityHidden(true)  // the AWAKE/IDLE text below says it
            Text("Caffeinate")
                .font(.title3.bold())
            Spacer()
            if manager.onHotspot {
                Label("Hotspot", systemImage: "personalhotspot")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(manager.isActive ? "AWAKE" : "IDLE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(manager.isActive ? .green : .secondary)
                Spacer()
                if manager.isActive && manager.lidMode {
                    Label("Lid can close", systemImage: "laptopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if manager.isActive && manager.shutdownAfter {
                    Label("Shutdown queued", systemImage: "power")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Text(manager.isActive ? manager.remainingText : "--:--")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel(manager.isActive ? "\(manager.remainingText) left" : "No session")

            if manager.isActive {
                ProgressView(value: manager.progress)
                    .tint(.orange)

                if let detail = sessionDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(role: .destructive) {
                        manager.stop()
                    } label: {
                        Text("Stop")
                            .frame(maxWidth: .infinity)
                    }
                    if manager.ending == .timer {
                        Button("+15m") { manager.extend(seconds: 15 * 60) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.12)))
    }

    private var sessionDetail: String? {
        var parts: [String] = []
        switch manager.ending {
        case .timer: break
        case .agentsIdle: parts.append(manager.agentsWorking ? "Ends when agents go idle (working now)" : "Ends when agents go idle")
        case .processExit: parts.append("Ends when \(manager.waitName ?? "the app") quits")
        }
        if manager.ending != .timer { parts.append("the timer is the hard cap") }
        if manager.lidMode, let b = manager.battery { parts.append("battery \(b.percent)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.lidReady {
                Button {
                    manager.commute()
                } label: {
                    Label("Commute: 45 min, lid closed", systemImage: "figure.walk")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            Picker("Ends", selection: $ends) {
                ForEach(Ends.allCases) { Text($0.rawValue).tag($0) }
            }

            switch ends {
            case .timer:
                HStack(spacing: 12) {
                    Stepper(value: $hours, in: 0...24) {
                        Text("\(hours) h")
                            .monospacedDigit()
                    }
                    Stepper(value: $minutes, in: 0...59, step: 5) {
                        Text("\(minutes) m")
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 6) {
                    ForEach(presets, id: \.0) { preset in
                        Button(preset.0) {
                            hours = preset.1 / 3600
                            minutes = (preset.1 % 3600) / 60
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            case .time:
                DatePicker("Until", selection: $untilTime, displayedComponents: .hourAndMinute)
            case .agents:
                Stepper(value: $manager.agentIdleMinutes, in: 1...60) {
                    Text("Idle for \(manager.agentIdleMinutes) min")
                        .monospacedDigit()
                }
                Text("Ends \(manager.agentIdleMinutes) min after Claude Code and Codex stop working. Stops after 2 h with the lid closed, 12 h otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .app:
                Picker("App", selection: $appPID) {
                    Text("Choose…").tag(pid_t(0))
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? "pid \(app.processIdentifier)").tag(app.processIdentifier)
                    }
                }
            }

            Toggle("Keep awake with lid closed", isOn: $lid)
                .toggleStyle(.switch)
                .font(.subheadline)
                .disabled(!manager.lidReady)
            if !manager.lidReady {
                Text("Set up lid mode under Settings first.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if lid, let seconds = plannedSeconds, seconds > CaffeinateManager.lidCap {
                Text("Lid sessions stop after 2 h.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !lid && (ends == .timer || ends == .time) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Shut down when finished", isOn: $shutdownAfter)
                        .toggleStyle(.switch)
                        .font(.subheadline)
                        .onChange(of: shutdownAfter) { on in
                            guard on else { return }
                            manager.requestShutdownPermission { granted in
                                if !granted { shutdownAfter = false }
                            }
                        }
                    if shutdownAfter {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                            Text("Force-quit warning: Auto-shutdown force-quits all open applications without saving unsaved files. A 60-second cancelable countdown will run before shutdown.")
                                .font(.caption2)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
                    }
                }
            }

            if let seconds = plannedSeconds, ends == .timer || ends == .time,
               let battery = manager.battery,
               let use = PowerInfo.estimatedUse(seconds: lid ? min(seconds, CaffeinateManager.lidCap) : seconds,
                                                battery: battery) {
                Text("≈ \(use)% battery at the current draw (\(battery.percent)% now)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                startSession()
            } label: {
                Text("Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(plannedSeconds == nil)
        }
    }

    private var settings: some View {
        DisclosureGroup("Settings") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(manager.lidReady ? "Lid mode ready" : "Lid mode needs setup", systemImage: "laptopcomputer")
                        .font(.subheadline)
                    Spacer()
                    if manager.lidBusy {
                        ProgressView().controlSize(.small)
                    } else if manager.lidReady {
                        Button("Revoke") { manager.revokeLid() }
                    } else {
                        Button("Set Up…") { manager.setUpLid() }
                    }
                }
                if !manager.lidReady {
                    Text("Asks for your password once. After that, any app running as you can run `pmset -a disablesleep 0/1` and `pmset -b lowpowermode 0/1` without a password (nothing else), so any of them could keep the Mac awake. Also installs a failsafe that restores sleep if Caffeinate dies.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if manager.screenLockImmediate == false {
                    Label("Set Lock Screen → “Require password after screen saver begins or display is turned off” to Immediately, so an opened lid shows the lock screen.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Keep display awake", isOn: $manager.keepDisplayAwake)
                    .toggleStyle(.switch)
                Label(manager.keepDisplayAwake ? "Display won't sleep; screen will remain awake without locking." : "Display sleeps normally; screen locks safely while Mac stays awake.",
                      systemImage: manager.keepDisplayAwake ? "exclamationmark.triangle.fill" : "lock.display")
                    .font(.caption2)
                    .foregroundStyle(manager.keepDisplayAwake ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Auto commute on iPhone hotspot", isOn: $manager.autoCommute)
                    .disabled(!manager.lidReady)
                Text("On the hotspot with agents working, turns on lid mode until they go idle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Launch at login", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { manager.launchAtLogin = $0 }
                ))

                TextField("ntfy.sh topic for phone alerts", text: $manager.ntfyTopic)
                    .textFieldStyle(.roundedBorder)
                if !manager.ntfyTopic.isEmpty && !Notifier.isValidTopic(manager.ntfyTopic) {
                    Text("Letters, digits, - and _ only")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 6)
        }
        .font(.subheadline)
    }

    private var historySection: some View {
        DisclosureGroup("Recent sessions") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.history) { record in
                        Text(record.line)
                            .font(.caption2.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .font(.subheadline)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != .current }
    }

    /// Duration the chosen options would run for, or nil when Start should be disabled.
    private var plannedSeconds: Int? {
        switch ends {
        case .timer:
            let total = hours * 3600 + minutes * 60
            return total > 0 ? total : nil
        case .time:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
            return secondsUntil(hour: parts.hour ?? 0, minute: parts.minute ?? 0, from: Date())
        case .agents:
            return lid ? CaffeinateManager.lidCap : CaffeinateManager.idleCap
        case .app:
            return appPID > 0 ? (lid ? CaffeinateManager.lidCap : CaffeinateManager.idleCap) : nil
        }
    }

    private func startSession() {
        guard let seconds = plannedSeconds else { return }
        switch ends {
        case .timer, .time:
            manager.start(seconds: seconds, lid: lid, shutdownAfter: !lid && shutdownAfter)
        case .agents:
            manager.start(seconds: 0, lid: lid, ending: .agentsIdle)
        case .app:
            manager.start(seconds: 0, lid: lid, ending: .processExit, waitPID: appPID)
        }
    }
}
