import Foundation
import UserNotifications

/// Session alerts: a local notification, plus an optional ntfy.sh push so the phone hears
/// about it while the Mac is in a bag.
enum Notifier {
    /// UNUserNotificationCenter crashes outside an .app bundle (swift run, tests).
    private static var inBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard inBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ text: String, ntfyTopic: String) {
        if inBundle {
            let content = UNMutableNotificationContent()
            content.title = "Caffeinate"
            content.body = text
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        guard isValidTopic(ntfyTopic), let url = URL(string: "https://ntfy.sh/\(ntfyTopic)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Caffeinate", forHTTPHeaderField: "Title")
        request.httpBody = Data(text.utf8)
        URLSession.shared.dataTask(with: request).resume()
    }

    /// The topic goes into a URL path: letters, digits, - and _ only.
    static func isValidTopic(_ topic: String) -> Bool {
        topic.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }
}
