import SwiftUI

@main
struct CaffeinateAppMain: App {
    @StateObject private var manager = CaffeinateManager()

    init() {
        // Single instance: a second copy would run its own caffeinate + timer.
        // The kernel drops the lock when this process dies, so it can't go stale.
        let fd = open(NSTemporaryDirectory() + "com.abraar.caffeinateapp.lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: manager)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                if manager.isActive {
                    Text(manager.remainingText)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
