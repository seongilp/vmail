import Foundation
import MailCore

/// 새로 도착한 메일에 규칙(자동 분류)과 부재중 자동 응답을 적용한다. vmail이 실행 중일 때만 동작한다.
enum MailAutomation {
    /// 규칙을 적용하고, 받은편지함에 남는(옮기거나 지우지 않은) 메일을 돌려준다.
    @discardableResult
    static func process(_ envelopes: [Envelope], store: MailStore, inbox: Mailbox) -> [Envelope] {
        guard !envelopes.isEmpty else { return [] }
        let remaining = applyRules(to: envelopes, store: store, mailbox: inbox)
        autoReply(to: remaining, store: store, inbox: inbox)
        return remaining
    }

    /// 규칙별로 묶어 한 번에 처리한다. 반환값: 받은편지함에 남는 메일.
    @discardableResult
    static func applyRules(to envelopes: [Envelope], store: MailStore, mailbox: Mailbox) -> [Envelope] {
        let rules = Preferences.rules
        guard !rules.isEmpty else { return envelopes }
        var groups: [UUID: (rule: MailRule, envelopes: [Envelope])] = [:]
        for envelope in envelopes {
            guard let rule = MailRule.firstMatch(for: envelope, accountEmail: store.account.email, in: rules) else { continue }
            groups[rule.id] = (rule, (groups[rule.id]?.envelopes ?? []) + [envelope])
        }
        var removed = Set<UInt32>()
        for (rule, matched) in groups.values {
            let log: (Error) -> Void = { NSLog("vmail: 규칙 ‘\(rule.name)’ 적용 실패 — \($0.localizedDescription)") }
            switch rule.action {
            case .move(let path):
                guard let destination = store.mailboxes.first(where: { $0.path == path }), destination != mailbox else {
                    NSLog("vmail: 규칙 ‘\(rule.name)’ 의 대상 사서함을 찾을 수 없습니다.")
                    continue
                }
                store.move(uids: matched.map(\.uid), from: mailbox, to: destination, failure: log)
                removed.formUnion(matched.map(\.uid))
            case .trash:
                store.delete(matched, in: mailbox, failure: log)
                removed.formUnion(matched.map(\.uid))
            case .markRead:
                store.setFlag("\\Seen", on: true, envelopes: matched, in: mailbox, failure: log)
            case .flag:
                store.setFlag("\\Flagged", on: true, envelopes: matched, in: mailbox, failure: log)
            }
        }
        return envelopes.filter { !removed.contains($0.uid) }
    }

    // MARK: - 부재중 자동 응답

    private static func autoReply(to envelopes: [Envelope], store: MailStore, inbox: Mailbox) {
        var settings = Preferences.autoReply
        let now = Date()
        guard settings.isActive(at: now) else { return }
        // 부재중 응답용으로 지정한 서명을 내용 끝에 붙인다.
        settings.body += ComposeDraft.block(Preferences.signature(for: .autoReply))
        // 한 번에 같은 사람의 메일이 여러 통 와도 한 통에만 응답한다.
        var handled = Set<String>()
        for envelope in envelopes {
            guard let recipient = AutoReplyPolicy.recipient(for: envelope),
                  handled.insert(recipient.email.lowercased()).inserted else { continue }
            let key = logKey(store, recipient)
            // 헤더를 받아 오기 전에 걸러낼 수 있는 것은 먼저 걸러 서버 요청을 줄인다.
            guard AutoReplyPolicy.shouldReply(to: envelope, headers: MIMEHeaders(fields: []), accountEmail: store.account.email,
                                              lastReplied: Preferences.autoReplyLog[key], now: now) else { continue }
            store.fetchHeaders(envelope, in: inbox, fields: AutoReplyPolicy.headerFields) { [weak store] result in
                guard let store, case .success(let headers) = result,
                      AutoReplyPolicy.shouldReply(to: envelope, headers: headers, accountEmail: store.account.email,
                                                  lastReplied: Preferences.autoReplyLog[key], now: Date()),
                      let reply = AutoReplyPolicy.reply(to: envelope, settings: settings, from: store.account.address) else { return }
                // 보내기 전에 기록해, 실패하더라도 같은 사람에게 연달아 시도하지 않는다.
                Preferences.autoReplyLog = Preferences.autoReplyLog.merging([key: Date()]) { _, new in new }
                store.send(reply) { error in
                    if let error { NSLog("vmail: 부재중 응답 발송 실패 — \(error.localizedDescription)") }
                }
            }
        }
    }

    private static func logKey(_ store: MailStore, _ recipient: Address) -> String {
        "\(store.account.email.lowercased())>\(recipient.email.lowercased())"
    }
}
