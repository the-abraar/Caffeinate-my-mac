import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = CaffeinateManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.launch()
    }

    /// caffeinate-my-mac:// URLs from the CLI, Shortcuts or agents.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(manager.handle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.quit()
    }
}

@main
struct CaffeinateAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    init() {
        // Single instance: a second copy would run its own caffeinate + timer.
        // The kernel drops the lock when this process dies, so it can't go stale.
        let fd = open(NSTemporaryDirectory() + "com.abraar.caffeinateapp.lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: app.manager)
        } label: {
            MenuBarLabel(manager: app.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var manager: CaffeinateManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
            if manager.isActive && manager.lidMode {
                Image(systemName: "laptopcomputer")
            }
            if manager.isActive {
                Text(manager.lidMode && manager.battery != nil
                     ? "\(manager.remainingText) · \(manager.battery?.percent ?? 0)%"
                     : manager.remainingText)
                    .monospacedDigit()
            }
        }
    }
}
