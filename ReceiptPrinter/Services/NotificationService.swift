import Foundation
import UserNotifications

final class NotificationService {
    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func requestAuthorization() {
        guard isAppBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
