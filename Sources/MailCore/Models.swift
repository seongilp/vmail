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
    case inbox, flagged, drafts, sent, all, junk, trash, other
}

public struct Mailbox: Codable, Hashable, Sendable {
    /// 서버에 그대로 보내는 경로(modified UTF-7 인코딩 상태)
    public let path: String
    /// 디코딩한 전체 이름
    public let name: String
    public let delimiter: String?
    public let attributes: [String]

    public init(path: String, name: String, delimiter: String?, attributes: [String]) {
        self.path = path
        self.name = name
        self.delimiter = delimiter
        self.attributes = attributes
    }

    public var role: MailboxRole {
        if path.uppercased() == "INBOX" { return .inbox }
        let attrs = Set(attributes.map { $0.lowercased() })
        if attrs.contains("\\sent") { return .sent }
        if attrs.contains("\\trash") { return .trash }
        if attrs.contains("\\drafts") { return .drafts }
        if attrs.contains("\\junk") { return .junk }
        if attrs.contains("\\all") || attrs.contains("\\archive") { return .all }
        if attrs.contains("\\flagged") { return .flagged }
        switch leafName.lowercased() {
        case "sent", "sent messages", "sent items", "sent mail", "보낸편지함", "보낸메일함": return .sent
        case "trash", "deleted messages", "deleted items", "휴지통": return .trash
        case "drafts", "draft", "임시보관함": return .drafts
        case "junk", "spam", "junk e-mail", "스팸메일함", "스팸편지함", "스팸": return .junk
        default: return .other
        }
    }

    public var components: [String] {
        guard let delimiter, !delimiter.isEmpty else { return [name] }
        return name.components(separatedBy: delimiter)
    }

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
    public let subject: String
    public let body: String
    public let attachments: [Attachment]
    public let inReplyTo: String?

    public init(from: Address, to: [Address], cc: [Address], subject: String, body: String,
                attachments: [Attachment] = [], inReplyTo: String? = nil) {
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
    }
}
