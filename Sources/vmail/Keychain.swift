import Foundation
import Security

/// 계정 비밀번호를 로그인 키체인에 보관한다.
enum Keychain {
    private static let service = "com.zihado.vmail"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(password: String, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        let attributes = query(account).merging([kSecValueData as String: Data(password.utf8)]) { _, new in new }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { NSLog("vmail: 키체인 저장 실패 (\(status))") }
        return status == errSecSuccess
    }

    static func password(account: String) -> String? {
        let attributes = query(account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
