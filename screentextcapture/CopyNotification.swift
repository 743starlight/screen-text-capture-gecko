import UserNotifications

enum CopyNotification {
    enum Delivery { case disabled, delivered, permissionMissing, failed }
    private static var generation = 0
    private static let identifier = "screentextcapture.copy.success"

    static func content(text: String, preview: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "コピーしました"
        content.body = preview ? String(text.prefix(160)) : "テキストをコピーしました（\(text.count)文字）。"
        content.interruptionLevel = .active
        content.sound = nil
        return content
    }

    static func successRequest(text: String, preview: Bool) -> UNNotificationRequest {
        UNNotificationRequest(identifier: identifier, content: content(text: text, preview: preview), trigger: nil)
    }

    static func deliver(text: String, settings: OCRSettings, completion: @escaping (Delivery) -> Void = { _ in }) {
        precondition(Thread.isMainThread)
        generation += 1
        let current = generation
        // トーストを選んだ場合に通知も出すと、バナーが表示される環境では重複する
        guard settings.copyFeedback == .notification else { completion(.disabled); return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { authorization in
            DispatchQueue.main.async {
                guard current == generation else { completion(.disabled); return }
                guard authorization.authorizationStatus == .authorized || authorization.authorizationStatus == .provisional else {
                    completion(.permissionMissing)
                    return
                }
                let request = successRequest(text: text, preview: settings.notificationPreview)
                // Keep one native notification; the HUD is only a fallback when delivery is unavailable.
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                center.add(request) { error in DispatchQueue.main.async { completion(error == nil ? .delivered : .failed) } }
            }
        }
    }

    /// Native notification and fallback HUD are mutually exclusive.
    static func shouldShowFallback(for delivery: Delivery, notificationsEnabled: Bool) -> Bool {
        guard notificationsEnabled else { return false }
        switch delivery {
        case .permissionMissing, .failed: return true
        case .disabled, .delivered: return false
        }
    }

    static func cancelPendingDelivery() {
        precondition(Thread.isMainThread)
        generation += 1
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func permissionStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    static func request(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
