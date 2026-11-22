import Foundation

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
}
