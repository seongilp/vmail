import Foundation
import MailCore
import UserNotifications

/// 받은편지함에 새로 도착한 메일을 알림 센터로 알린다.
enum NewMailNotifier {
    private static let maxIndividual = 3

    /// 앱 번들로 실행 중일 때만 알림 센터를 쓸 수 있다.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error { NSLog("vmail: 알림 권한 요청 실패 — \(error.localizedDescription)") }
        }
    }

    static func notify(_ envelopes: [Envelope]) {
        guard Preferences.notifyNewMail, !envelopes.isEmpty, let center else { return }
        if envelopes.count > maxIndividual {
            post("새로운 메일 \(envelopes.count)개", body: envelopes.prefix(maxIndividual)
                .map { $0.from.first?.displayName ?? "" }.joined(separator: ", ") + " 외", to: center)
            return
        }
        for envelope in envelopes {
            post(envelope.from.first?.displayName ?? "새로운 메일",
                 body: envelope.subject.isEmpty ? "(제목 없음)" : envelope.subject, to: center)
        }
    }

    private static func post(_ title: String, body: String, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("vmail: 알림 표시 실패 — \(error.localizedDescription)") }
        }
    }
}
