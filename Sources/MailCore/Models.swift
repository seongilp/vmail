import Foundation

public struct Address: Codable, Hashable, Sendable {
    public let name: String?
    public let email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }

    /// 목록에 보여줄 짧은 이름
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return email
    }

    /// "이름 <주소>" 형태
    public var fullDisplay: String {
        if let name, !name.isEmpty { return "\(name) <\(email)>" }
        return email
    }
}

public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox, flagged, important, drafts, sent, all, junk, trash, other
}

public struct Mailbox: Codable, Hashable, Sendable {
    /// 서버에 그대로 보내는 경로(modified UTF-7 인코딩 상태)
    public let path: String
    /// 디코딩한 전체 이름
    public let name: String
    public let delimiter: String?
    public let attributes: [String]
    public let role: MailboxRole

    /// role을 생략하면 속성과 이름으로 추정한다.
    public init(path: String, name: String, delimiter: String?, attributes: [String], role: MailboxRole? = nil) {
        self.path = path
        self.name = name
        self.delimiter = delimiter
        self.attributes = attributes
        self.role = role ?? Self.attributeRole(path: path, attributes: attributes)
            ?? Self.nameRole(Self.components(name, delimiter).last ?? name)
    }

    /// 서버가 special-use 속성으로 알려 준 역할 (가장 믿을 수 있다)
    static func attributeRole(path: String, attributes: [String]) -> MailboxRole? {
        if path.uppercased() == "INBOX" { return .inbox }
        let attrs = Set(attributes.map { $0.lowercased() })
        if attrs.contains("\\sent") { return .sent }
        if attrs.contains("\\trash") { return .trash }
        if attrs.contains("\\drafts") { return .drafts }
        if attrs.contains("\\junk") { return .junk }
        if attrs.contains("\\all") || attrs.contains("\\archive") { return .all }
        if attrs.contains("\\flagged") { return .flagged }
        if attrs.contains("\\important") { return .important }
        return nil
    }

    /// 속성이 없는 서버를 위한 이름 기반 추정
    static func nameRole(_ leaf: String) -> MailboxRole {
        switch leaf.lowercased() {
        case "sent", "sent messages", "sent items", "sent mail", "보낸편지함", "보낸메일함": return .sent
        case "trash", "deleted messages", "deleted items", "휴지통": return .trash
        case "drafts", "draft", "임시보관함": return .drafts
        case "junk", "spam", "junk e-mail", "스팸메일함", "스팸편지함", "스팸": return .junk
        default: return .other
        }
    }

    /// 같은 역할이 여럿이면 하나만 남기고 나머지는 일반 폴더로 돌린다.
    /// 속성으로 확인된 사서함이 우선하고, 없으면 이름으로 추정한 첫 번째를 쓴다.
    public static func resolvingDuplicateRoles(_ mailboxes: [Mailbox]) -> [Mailbox] {
        var winners: [MailboxRole: String] = [:]
        for mailbox in mailboxes where mailbox.role != .other {
            let confirmed = attributeRole(path: mailbox.path, attributes: mailbox.attributes) == mailbox.role
            if winners[mailbox.role] == nil || (confirmed && !isConfirmed(winners[mailbox.role], in: mailboxes)) {
                winners[mailbox.role] = mailbox.path
            }
        }
        return mailboxes.map { mailbox in
            guard mailbox.role != .other, winners[mailbox.role] != mailbox.path else { return mailbox }
            return Mailbox(path: mailbox.path, name: mailbox.name, delimiter: mailbox.delimiter,
                           attributes: mailbox.attributes, role: .other)
        }
    }

    private static func isConfirmed(_ path: String?, in mailboxes: [Mailbox]) -> Bool {
        guard let mailbox = mailboxes.first(where: { $0.path == path }) else { return false }
        return attributeRole(path: mailbox.path, attributes: mailbox.attributes) == mailbox.role
    }

    private static func components(_ name: String, _ delimiter: String?) -> [String] {
        guard let delimiter, !delimiter.isEmpty else { return [name] }
        return name.components(separatedBy: delimiter)
    }

    public var components: [String] { Self.components(name, delimiter) }

    public var leafName: String { components.last ?? name }

    public var isSelectable: Bool {
        let attrs = Set(attributes.map { $0.lowercased() })
        return !attrs.contains("\\noselect") && !attrs.contains("\\nonexistent")
    }
}

public struct Envelope: Codable, Hashable, Sendable {
    public let uid: UInt32
    public let flags: [String]
    public let date: Date
    public let size: Int
    public let subject: String
    public let from: [Address]
    public let to: [Address]
    public let cc: [Address]
    public let replyTo: [Address]
    public let messageID: String?

    public init(uid: UInt32, flags: [String], date: Date, size: Int, subject: String,
                from: [Address], to: [Address], cc: [Address], replyTo: [Address], messageID: String?) {
        self.uid = uid
        self.flags = flags
        self.date = date
        self.size = size
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.messageID = messageID
    }

    public var isSeen: Bool { hasFlag("\\Seen") }
    public var isFlagged: Bool { hasFlag("\\Flagged") }

    public func hasFlag(_ flag: String) -> Bool {
        flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }

    /// 플래그를 더하거나 뺀 새 Envelope
    public func settingFlag(_ flag: String, _ on: Bool) -> Envelope {
        let without = flags.filter { $0.caseInsensitiveCompare(flag) != .orderedSame }
        return Envelope(uid: uid, flags: on ? without + [flag] : without, date: date, size: size,
                        subject: subject, from: from, to: to, cc: cc, replyTo: replyTo, messageID: messageID)
    }
}

public struct MailboxStatus: Equatable, Sendable {
    public let exists: Int
    public let uidValidity: UInt32
}

public struct Attachment: Hashable, Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

public struct OutgoingMessage: Sendable {
    public let from: Address
    public let to: [Address]
    public let cc: [Address]
    /// 봉투에만 쓰이고 헤더에는 넣지 않는다.
    public let bcc: [Address]
    public let subject: String
    public let body: String
    public let attachments: [Attachment]
    public let inReplyTo: String?

    public init(from: Address, to: [Address], cc: [Address], bcc: [Address] = [], subject: String, body: String,
                attachments: [Attachment] = [], inReplyTo: String? = nil) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
    }
}
