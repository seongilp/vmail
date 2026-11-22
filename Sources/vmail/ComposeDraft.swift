import Foundation
import MailCore

/// 작성 창의 초기 내용
struct ComposeDraft {
    let from: Address
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var attachments: [Attachment] = []
    /// 임시보관함의 메일을 이어 쓰는 경우 원본 (보내거나 다시 저장하면 지운다)
    var sourceDraft: (mailbox: Mailbox, uid: UInt32)?

    /// 본문에 넣은 서명 (작성 창에서 다른 서명으로 바꿀 때 찾는다)
    var signature: Signature?

    init(from: Address, use: SignatureUse = .newMail) {
        self.from = from
        signature = Preferences.signature(for: use)
        body = Self.block(signature)
        // 작성 설정: 자동으로 나를 참조/숨은 참조에 넣기
        switch Preferences.copySelf {
        case .cc: cc = from.email
        case .bcc: bcc = from.email
        case .none: break
        }
    }

    /// 본문 끝(인용문 앞)에 붙는 서명
    static func block(_ signature: Signature?) -> String {
        let text = signature?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "" : "\n\n\(text)"
    }

    /// 답장 초안: 받는 사람·제목·인용문을 채운다.
    static func reply(to envelope: Envelope, message: ParsedMessage, account: Account, all: Bool) -> ComposeDraft {
        var draft = ComposeDraft(from: account.address, use: .reply)
        let me = account.email.lowercased()
        let primary = envelope.replyTo.isEmpty ? envelope.from : envelope.replyTo
        draft.to = primary.map(\.fullDisplay).joined(separator: ", ")
        if all {
            let primaryEmails = Set(primary.map { $0.email.lowercased() })
            let others = (envelope.to + envelope.cc).filter {
                $0.email.lowercased() != me && !primaryEmails.contains($0.email.lowercased())
            }
            draft.cc = ([draft.cc] + others.map(\.fullDisplay)).filter { !$0.isEmpty }.joined(separator: ", ")
        }
        draft.subject = prefixed(envelope.subject, with: "Re:")
        draft.inReplyTo = envelope.messageID
        let sender = envelope.from.first?.displayName ?? "보낸 사람"
        if Preferences.quoteOriginal {
            let original = message.plainText.replacingOccurrences(of: "\r\n", with: "\n")
            let text = Preferences.increaseQuoteLevel ? quoted(original) : original
            draft.body += "\n\n\(ListDateFormatter.detailed(envelope.date))에 \(sender) 님이 작성:\n\(text)\n"
        }
        return draft
    }

    /// 전달 초안: 원문 헤더·본문·첨부를 그대로 싣는다.
    static func forward(_ envelope: Envelope, message: ParsedMessage, account: Account) -> ComposeDraft {
        var draft = ComposeDraft(from: account.address, use: .reply)
        draft.subject = prefixed(envelope.subject, with: "Fwd:")
        let header = [
            "---------- 전달된 메시지 ----------",
            "보낸 사람: \(envelope.from.map(\.fullDisplay).joined(separator: ", "))",
            "날짜: \(ListDateFormatter.detailed(envelope.date))",
            "제목: \(envelope.subject)",
            "받는 사람: \(envelope.to.map(\.fullDisplay).joined(separator: ", "))",
        ].joined(separator: "\n")
        draft.body += "\n\n\(header)\n\n\(message.plainText)\n"
        draft.attachments = message.attachments
        return draft
    }

    /// 임시보관함에 있던 메일을 다시 연다.
    static func editing(_ envelope: Envelope, in mailbox: Mailbox, message: ParsedMessage, account: Account) -> ComposeDraft {
        var draft = ComposeDraft(from: account.address)
        draft.to = message.to
        draft.cc = message.cc
        draft.subject = envelope.subject
        draft.body = message.plainText.replacingOccurrences(of: "\r\n", with: "\n")
        draft.signature = nil   // 저장된 본문에 이미 들어 있다
        draft.attachments = message.attachments
        draft.sourceDraft = (mailbox, envelope.uid)
        return draft
    }

    /// mailto:주소?subject=…&body=…&cc=… 링크
    static func mailto(_ url: URL, account: Account) -> ComposeDraft? {
        guard url.scheme?.lowercased() == "mailto",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var draft = ComposeDraft(from: account.address)
        draft.to = components.path.removingPercentEncoding ?? components.path
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "subject": draft.subject = value
            case "cc": draft.cc = value
            case "bcc": draft.bcc = value
            case "body": draft.body = value + draft.body
            case "to": draft.to = [draft.to, value].filter { !$0.isEmpty }.joined(separator: ", ")
            default: break
            }
        }
        return draft
    }

    private static func prefixed(_ subject: String, with prefix: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}
