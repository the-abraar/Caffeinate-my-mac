import SwiftUI

@main
struct CaffeinateAppMain: App {
    @StateObject private var manager = CaffeinateManager()

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
