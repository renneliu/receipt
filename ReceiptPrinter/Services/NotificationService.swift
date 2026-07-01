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

    func notifyNewOrder(_ order: PendingOrder) {
        guard isAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "新订单待打印"
        content.body = "\(order.cinemaName): \(order.displayTitle)"
        content.sound = .default
        content.userInfo = ["orderId": order.id.uuidString]
        let request = UNNotificationRequest(identifier: order.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
