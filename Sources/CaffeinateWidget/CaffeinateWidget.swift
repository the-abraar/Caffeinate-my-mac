import WidgetKit
import SwiftUI

struct SessionEntry: TimelineEntry {
    let date: Date
    var start: Date?
    var end: Date?
    var shutdown = false
    var lid = false
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SessionEntry { SessionEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (SessionEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionEntry>) -> Void) {
        let entry = current()
        var entries = [entry]
        // Flip to idle when the session ends; the app reloads us on start/stop.
        if let end = entry.end { entries.append(SessionEntry(date: end)) }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func current() -> SessionEntry {
        // Sandboxed: NSHomeDirectory() is the container, so resolve the real home.
        guard let pw = getpwuid(getuid()) else { return SessionEntry(date: .now) }
        let path = String(cString: pw.pointee.pw_dir) + "/Library/Application Support/Caffeinate/state.plist"
        guard let state = NSDictionary(contentsOfFile: path),
              let end = (state["end"] as? Double).map(Date.init(timeIntervalSince1970:)),
              let total = state["total"] as? Int,
              end > .now
        else { return SessionEntry(date: .now) }
        return SessionEntry(date: .now, start: end.addingTimeInterval(-Double(total)), end: end,
                            shutdown: state["shutdown"] as? Bool ?? false, lid: state["lid"] as? Bool ?? false)
    }
}

struct CaffeinateWidgetView: View {
    let entry: SessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.end != nil ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(entry.end != nil ? .orange : .secondary)
                Text(entry.end != nil ? "AWAKE" : "IDLE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(entry.end != nil ? .green : .secondary)
                Spacer()
                if entry.lid {
                    Image(systemName: "laptopcomputer").foregroundStyle(.orange)
                }
                if entry.shutdown {
                    Image(systemName: "power").foregroundStyle(.red)
                }
            }
            if let start = entry.start, let end = entry.end {
                Text(timerInterval: start...end, countsDown: true)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(.orange)
            } else {
                Text("--:--")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .widgetBackground()
    }
}

extension View {
    @ViewBuilder func widgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
            padding()
        }
    }
}

@main
struct CaffeinateWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CaffeinateWidget", provider: Provider()) { entry in
            CaffeinateWidgetView(entry: entry)
        }
        .configurationDisplayName("Caffeinate")
        .description("Time left in the current awake session.")
        .supportedFamilies([.systemSmall])
    }
}
