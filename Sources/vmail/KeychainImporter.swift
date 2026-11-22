import Foundation
import MailCore
import Security

/// 다른 메일 앱(Apple Mail 등)이 로그인 키체인에 저장해 둔 IMAP 계정
struct ImportableAccount: Equatable {
    let server: String
    let username: String
    let port: Int

    var title: String { "\(username) — \(server)" }

    /// 키체인 항목으로 계정 설정을 추정한다.
    var account: Account {
        let email: String
        if username.contains("@") {
            email = username
        } else {
            let domain = server.lowercased().hasPrefix("imap.") ? String(server.dropFirst(5)) : server
            email = "\(username)@\(domain)"
        }
        let preset = Account.preset(email: email)
        return Account(displayName: preset.displayName, email: email, username: username,
                       imapHost: server, imapPort: port > 0 ? port : preset.imapPort,
                       smtpHost: preset.smtpHost, smtpPort: preset.smtpPort)
    }
}

/// 키체인에서 IMAP 계정을 찾아 가져온다.
/// 목록 조회는 속성만 읽어 묻지 않고, 비밀번호를 읽을 때 macOS가 사용자에게 허용 여부를 묻는다.
/// OAuth로 로그인한 계정(Apple Mail의 Gmail 등)은 비밀번호 자체가 없어 여기에 나타나지 않는다.
enum KeychainImporter {
    private static let imapProtocols: Set<String> = [kSecAttrProtocolIMAP as String, kSecAttrProtocolIMAPS as String]

    static func candidates() -> [ImportableAccount] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound { NSLog("vmail: 키체인 조회 실패 (\(status))") }
            return []
        }
        var found: [ImportableAccount] = []
        for item in items {
            guard let server = item[kSecAttrServer as String] as? String,
                  let username = item[kSecAttrAccount as String] as? String,
                  !server.isEmpty, !username.isEmpty else { continue }
            let proto = item[kSecAttrProtocol as String] as? String ?? ""
            guard imapProtocols.contains(proto) || server.lowercased().hasPrefix("imap.") else { continue }
            let candidate = ImportableAccount(server: server, username: username,
                                              port: item[kSecAttrPort as String] as? Int ?? 0)
            if !found.contains(where: { $0.server == server && $0.username == username }) {
                found.append(candidate)
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 비밀번호를 읽는다. 시스템 허용 창이 뜰 수 있어 백그라운드에서 실행하고 메인 큐로 돌려준다.
    static func password(for candidate: ImportableAccount, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: candidate.server,
                kSecAttrAccount as String: candidate.username,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            let password = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
            if status != errSecSuccess { NSLog("vmail: 키체인 비밀번호 읽기 실패 (\(status))") }
            DispatchQueue.main.async { completion(password) }
        }
    }
}
