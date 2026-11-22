import Foundation
import MailCore

/// 사용자 설정 (UserDefaults)
enum Preferences {
    private static let signatureKey = "signature"
    private static let remoteKey = "alwaysLoadRemoteContent"
    private static let notifyKey = "notifyNewMail"

    static var signature: String {
        get { UserDefaults.standard.string(forKey: signatureKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: signatureKey) }
    }

    /// 원격 이미지를 묻지 않고 항상 불러올지 (기본: 차단)
    static var alwaysLoadRemoteContent: Bool {
        get { UserDefaults.standard.bool(forKey: remoteKey) }
        set { UserDefaults.standard.set(newValue, forKey: remoteKey) }
    }

    /// 새 메일 알림 (기본: 켬)
    static var notifyNewMail: Bool {
        get { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: notifyKey) }
    }

    // MARK: - 부재중 자동 응답 / 규칙

    private static let autoReplyKey = "autoReply"
    private static let autoReplyLogKey = "autoReplyLog"
    private static let rulesKey = "rules"

    static var autoReply: AutoReplySettings {
        get { decode(AutoReplySettings.self, autoReplyKey) ?? AutoReplySettings() }
        set { encode(newValue, autoReplyKey) }
    }

    /// 자동 응답을 보낸 상대와 시각 (같은 사람에게 반복해서 보내지 않기 위한 기록)
    static var autoReplyLog: [String: Date] {
        get { decode([String: Date].self, autoReplyLogKey) ?? [:] }
        set { encode(newValue, autoReplyLogKey) }
    }

    static var rules: [MailRule] {
        get { decode([MailRule].self, rulesKey) ?? [] }
        set { encode(newValue, rulesKey) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("vmail: 설정 해석 실패(\(key)) — \(error.localizedDescription)")
            return nil
        }
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            NSLog("vmail: 설정 저장 실패(\(key)) — \(error.localizedDescription)")
        }
    }
}
