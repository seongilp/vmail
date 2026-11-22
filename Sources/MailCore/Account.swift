import Foundation

public struct Account: Codable, Equatable, Sendable {
    public let displayName: String
    public let email: String
    public let username: String
    public let imapHost: String
    public let imapPort: Int
    public let smtpHost: String
    public let smtpPort: Int

    public init(displayName: String, email: String, username: String,
                imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int) {
        self.displayName = displayName
        self.email = email
        self.username = username
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
    }

    public static let imapTLSPort = 993
    public static let smtpTLSPort = 465
    public static let smtpSubmissionPort = 587

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// 이 Mac 안에서 도는 로컬 브리지(루프백)는 평문을 허용하고, 그 외에는 항상 암호화한다.
    public var imapSecurity: ConnectionSecurity {
        if Self.loopbackHosts.contains(imapHost.lowercased()) { return .none }
        return imapPort == Self.imapTLSPort ? .tls : .startTLS
    }

    public var smtpSecurity: ConnectionSecurity {
        if Self.loopbackHosts.contains(smtpHost.lowercased()) { return .none }
        return smtpPort == Self.smtpTLSPort ? .tls : .startTLS
    }
    public var address: Address { Address(name: displayName.isEmpty ? nil : displayName, email: email) }

    /// 보낸 메일을 서버가 알아서 보낸편지함에 넣어 주는지 (그렇다면 APPEND 하지 않는다)
    public var serverSavesSentMail: Bool { smtpHost.lowercased().hasSuffix("gmail.com") }

    /// 이메일 도메인으로 서버 설정을 추정한다.
    public static func preset(email: String, displayName: String = "") -> Account {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: "@")
        let local = parts.first ?? ""
        let domain = (parts.count > 1 ? parts[1] : "").lowercased()

        func make(_ imap: String, _ smtp: String, smtpPort: Int = smtpTLSPort, username: String? = nil) -> Account {
            Account(displayName: displayName, email: trimmed, username: username ?? trimmed,
                    imapHost: imap, imapPort: imapTLSPort, smtpHost: smtp, smtpPort: smtpPort)
        }

        switch domain {
        case "gmail.com", "googlemail.com":
            return make("imap.gmail.com", "smtp.gmail.com")
        case "naver.com":
            return make("imap.naver.com", "smtp.naver.com", username: local)
        case "daum.net", "hanmail.net":
            return make("imap.daum.net", "smtp.daum.net", username: local)
        case "kakao.com":
            return make("imap.kakao.com", "smtp.kakao.com", username: local)
        case "icloud.com", "me.com", "mac.com":
            return make("imap.mail.me.com", "smtp.mail.me.com", smtpPort: smtpSubmissionPort)
        case "yahoo.com":
            return make("imap.mail.yahoo.com", "smtp.mail.yahoo.com")
        case "":
            return make("", "", smtpPort: smtpSubmissionPort)
        default:
            return make("imap.\(domain)", "smtp.\(domain)", smtpPort: smtpSubmissionPort)
        }
    }
}
