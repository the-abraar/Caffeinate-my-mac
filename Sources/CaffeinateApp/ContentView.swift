import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: CaffeinateManager

    @State private var hours: Int = 2
    @State private var minutes: Int = 0
    @State private var shutdownAfter: Bool = false

    private let presets: [(String, Int)] = [
        ("30m", 30 * 60),
        ("1h", 60 * 60),
        ("2h", 2 * 60 * 60),
        ("3h", 3 * 60 * 60)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            statusCard

            if !manager.isActive {
                configSection
            }

            Divider()

            Text(manager.lastSessionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Quit") {
                    manager.stop(manual: true, quiet: true)
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Image(systemName: manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.title2)
                .foregroundStyle(manager.isActive ? .orange : .secondary)
            Text("Caffeinate")
                .font(.title3.bold())
            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(manager.isActive ? "AWAKE" : "IDLE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(manager.isActive ? .green : .secondary)
                Spacer()
                if manager.isActive && manager.shutdownAfter {
                    Label("Shutdown queued", systemImage: "power")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Text(manager.isActive ? manager.remainingText : "--:--")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()

            if manager.isActive {
                ProgressView(value: manager.progress)
                    .tint(.orange)
            }

            if manager.isActive {
                Button(role: .destructive) {
                    manager.stop(manual: true)
                } label: {
                    Text("Stop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.12)))
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duration")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

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

            Toggle("Shut down when finished", isOn: $shutdownAfter)
                .toggleStyle(.switch)
                .font(.subheadline)

            Button {
                let total = hours * 3600 + minutes * 60
                guard total > 0 else { return }
                manager.start(durationSeconds: total, shutdownAfter: shutdownAfter)
            } label: {
                Text("Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(hours == 0 && minutes == 0)
        }
    }
}
