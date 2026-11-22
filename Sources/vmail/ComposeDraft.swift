import Foundation
import MailCore

/// 작성 창의 초기 내용
struct ComposeDraft {
    let from: Address
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?

    init(from: Address) {
        self.from = from
    }

    /// 답장 초안: 받는 사람·제목·인용문을 채운다.
    static func reply(to envelope: Envelope, message: ParsedMessage, account: Account, all: Bool) -> ComposeDraft {
        var draft = ComposeDraft(from: account.address)
        let me = account.email.lowercased()
        let primary = envelope.replyTo.isEmpty ? envelope.from : envelope.replyTo
        draft.to = primary.map(\.fullDisplay).joined(separator: ", ")
        if all {
            let primaryEmails = Set(primary.map { $0.email.lowercased() })
            let others = (envelope.to + envelope.cc).filter {
                $0.email.lowercased() != me && !primaryEmails.contains($0.email.lowercased())
            }
            draft.cc = others.map(\.fullDisplay).joined(separator: ", ")
        }
        let subject = envelope.subject
        draft.subject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        draft.inReplyTo = envelope.messageID

        let sender = envelope.from.first?.displayName ?? "보낸 사람"
        let quoted = message.plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        draft.body = "\n\n\(ListDateFormatter.detailed(envelope.date))에 \(sender) 님이 작성:\n\(quoted)\n"
        return draft
    }
}
