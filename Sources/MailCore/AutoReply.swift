import Foundation

/// 부재중 자동 응답 설정
public struct AutoReplySettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var subject: String
    public var body: String
    /// 기간을 지정하지 않으면 nil (켜 둔 동안 계속)
    public var start: Date?
    public var end: Date?

    public init(isEnabled: Bool = false, subject: String = "부재중 자동 응답",
                body: String = "안녕하세요. 지금은 부재중이라 메일 확인이 늦어질 수 있습니다. 돌아오는 대로 답장드리겠습니다.",
                start: Date? = nil, end: Date? = nil) {
        self.isEnabled = isEnabled
        self.subject = subject
        self.body = body
        self.start = start
        self.end = end
    }

    public func isActive(at now: Date) -> Bool {
        guard isEnabled else { return false }
        if let start, now < start { return false }
        if let end, now > end { return false }
        return true
    }
}

/// 자동 응답을 보내도 되는 메일인지 판단한다 (RFC 3834 권고를 따른다).
public enum AutoReplyPolicy {
    /// 같은 사람에게 다시 응답하기까지의 최소 간격
    public static let minimumInterval: TimeInterval = 4 * 24 * 60 * 60
    /// 판단에 필요한 헤더 (IMAP으로 이것만 가져온다)
    public static let headerFields = ["AUTO-SUBMITTED", "PRECEDENCE", "LIST-ID", "LIST-UNSUBSCRIBE", "X-AUTO-RESPONSE-SUPPRESS"]

    private static let automatedLocalParts = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
                                              "mailer-daemon", "postmaster", "bounce", "notification", "notifications"]

    /// 응답을 받을 주소 (Reply-To 우선)
    public static func recipient(for envelope: Envelope) -> Address? {
        envelope.replyTo.first ?? envelope.from.first
    }

    public static func shouldReply(to envelope: Envelope, headers: MIMEHeaders, accountEmail: String,
                                   lastReplied: Date?, now: Date) -> Bool {
        guard let recipient = recipient(for: envelope) else { return false }
        let me = accountEmail.lowercased()
        let sender = recipient.email.lowercased()
        // 나 자신, 자동 발송 주소에는 보내지 않는다.
        if sender == me { return false }
        let local = sender.components(separatedBy: "@").first ?? ""
        if automatedLocalParts.contains(where: { local.contains($0) }) { return false }
        // 나에게 직접 온 메일만 (숨은 참조·메일링 리스트 제외)
        guard (envelope.to + envelope.cc).contains(where: { $0.email.lowercased() == me }) else { return false }
        // 자동 생성 메일·대량 메일·리스트에는 보내지 않는다.
        if let auto = headers["auto-submitted"], auto.lowercased() != "no" { return false }
        if let precedence = headers["precedence"]?.lowercased(), ["bulk", "list", "junk"].contains(precedence) { return false }
        if headers["list-id"] != nil || headers["list-unsubscribe"] != nil { return false }
        if headers["x-auto-response-suppress"] != nil { return false }
        // 같은 사람에게는 일정 간격으로 한 번만
        if let lastReplied, now.timeIntervalSince(lastReplied) < minimumInterval { return false }
        return true
    }

    /// 자동 응답 메시지를 만든다.
    public static func reply(to envelope: Envelope, settings: AutoReplySettings, from: Address) -> OutgoingMessage? {
        guard let recipient = recipient(for: envelope) else { return nil }
        let subject = envelope.subject.isEmpty ? settings.subject : "\(settings.subject): \(envelope.subject)"
        return OutgoingMessage(from: from, to: [recipient], cc: [], subject: subject, body: settings.body,
                               inReplyTo: envelope.messageID, isAutoReply: true)
    }
}
