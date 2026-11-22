import Foundation

/// 조건에 맞는 새 메일을 자동으로 분류하는 규칙
public struct MailRule: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case from, to, subject, any
    }

    public enum Action: Codable, Equatable, Sendable {
        case move(path: String)   // 사서함으로 이동
        case markRead
        case flag
        case trash
    }

    public var id: UUID
    public var name: String
    /// 이 규칙이 적용되는 계정
    public var accountEmail: String
    public var isEnabled: Bool
    public var field: Field
    public var keyword: String
    public var action: Action

    public init(id: UUID = UUID(), name: String, accountEmail: String, isEnabled: Bool = true,
                field: Field, keyword: String, action: Action) {
        self.id = id
        self.name = name
        self.accountEmail = accountEmail
        self.isEnabled = isEnabled
        self.field = field
        self.keyword = keyword
        self.action = action
    }

    /// 대소문자 구분 없이 키워드가 들어 있는지 본다. 빈 키워드는 아무것도 매치하지 않는다.
    public func matches(_ envelope: Envelope) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespaces)
        guard isEnabled, !needle.isEmpty else { return false }
        func text(_ addresses: [Address]) -> [String] { addresses.flatMap { [$0.name ?? "", $0.email] } }
        let haystack: [String]
        switch field {
        case .from: haystack = text(envelope.from)
        case .to: haystack = text(envelope.to + envelope.cc)
        case .subject: haystack = [envelope.subject]
        case .any: haystack = text(envelope.from + envelope.to + envelope.cc) + [envelope.subject]
        }
        return haystack.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// 계정의 규칙 중 처음 맞는 것 하나를 고른다 (위에 있는 규칙이 우선).
    public static func firstMatch(for envelope: Envelope, accountEmail: String, in rules: [MailRule]) -> MailRule? {
        rules.first { $0.accountEmail.lowercased() == accountEmail.lowercased() && $0.matches(envelope) }
    }
}
