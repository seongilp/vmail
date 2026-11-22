import XCTest
@testable import MailCore

final class AutoReplyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = "me@example.com"

    private func envelope(from: String = "kim@corp.io", to: [String] = ["me@example.com"], cc: [String] = [],
                          replyTo: [String] = [], subject: String = "안녕하세요") -> Envelope {
        func addresses(_ list: [String]) -> [Address] { list.map { Address(name: nil, email: $0) } }
        return Envelope(uid: 1, flags: [], date: now, size: 0, subject: subject, from: addresses([from]),
                        to: addresses(to), cc: addresses(cc), replyTo: addresses(replyTo), messageID: "<m1@corp.io>")
    }

    private func headers(_ text: String = "") -> MIMEHeaders {
        MIMEHeaders.parse(Data(text.utf8))
    }

    private func should(_ envelope: Envelope, _ head: String = "", last: Date? = nil) -> Bool {
        AutoReplyPolicy.shouldReply(to: envelope, headers: headers(head), accountEmail: me, lastReplied: last, now: now)
    }

    func testRepliesToDirectPersonalMail() {
        XCTAssertTrue(should(envelope()))
        XCTAssertTrue(should(envelope(to: ["other@x.io"], cc: ["ME@example.com"])))
        XCTAssertTrue(should(envelope(), "Auto-Submitted: no"))
    }

    func testSkipsSelfAndAutomatedSenders() {
        XCTAssertFalse(should(envelope(from: "me@example.com")))
        XCTAssertFalse(should(envelope(from: "no-reply@shop.io")))
        XCTAssertFalse(should(envelope(from: "MAILER-DAEMON@mx.io")))
        XCTAssertFalse(should(envelope(from: "kim@corp.io", replyTo: ["notifications@corp.io"])))
    }

    func testSkipsMailNotAddressedToMe() {
        XCTAssertFalse(should(envelope(to: ["list@groups.io"])))
    }

    func testSkipsAutomatedAndListMail() {
        XCTAssertFalse(should(envelope(), "Auto-Submitted: auto-generated"))
        XCTAssertFalse(should(envelope(), "Precedence: bulk"))
        XCTAssertFalse(should(envelope(), "List-Id: <dev.example.com>"))
        XCTAssertFalse(should(envelope(), "List-Unsubscribe: <mailto:u@x.io>"))
        XCTAssertFalse(should(envelope(), "X-Auto-Response-Suppress: All"))
    }

    func testRepliesOncePerInterval() {
        XCTAssertFalse(should(envelope(), last: now.addingTimeInterval(-3600)))
        XCTAssertTrue(should(envelope(), last: now.addingTimeInterval(-AutoReplyPolicy.minimumInterval - 1)))
    }

    func testSettingsActiveWindow() {
        var settings = AutoReplySettings(isEnabled: false)
        XCTAssertFalse(settings.isActive(at: now))
        settings.isEnabled = true
        XCTAssertTrue(settings.isActive(at: now))
        settings.start = now.addingTimeInterval(60)
        XCTAssertFalse(settings.isActive(at: now))
        settings.start = now.addingTimeInterval(-60)
        settings.end = now.addingTimeInterval(-1)
        XCTAssertFalse(settings.isActive(at: now))
        settings.end = now.addingTimeInterval(60)
        XCTAssertTrue(settings.isActive(at: now))
    }

    func testRuleMatching() {
        let mail = envelope(from: "News@Shop.io", subject: "주간 뉴스레터 Café")
        func rule(_ field: MailRule.Field, _ keyword: String, enabled: Bool = true, account: String = "me@example.com") -> MailRule {
            MailRule(name: "r", accountEmail: account, isEnabled: enabled, field: field, keyword: keyword, action: .markRead)
        }
        XCTAssertTrue(rule(.from, "shop.io").matches(mail))
        XCTAssertTrue(rule(.subject, "뉴스레터").matches(mail))
        XCTAssertTrue(rule(.subject, "cafe").matches(mail))
        XCTAssertTrue(rule(.to, "ME@example").matches(mail))
        XCTAssertTrue(rule(.any, "news@").matches(mail))
        XCTAssertFalse(rule(.subject, "shop.io").matches(mail))
        XCTAssertFalse(rule(.from, "  ").matches(mail))
        XCTAssertFalse(rule(.from, "shop.io", enabled: false).matches(mail))

        let rules = [rule(.from, "nomatch"), rule(.from, "shop", account: "other@x.io"),
                     MailRule(name: "win", accountEmail: "ME@example.com", field: .subject, keyword: "뉴스", action: .move(path: "News")),
                     rule(.any, "shop")]
        XCTAssertEqual(MailRule.firstMatch(for: mail, accountEmail: "me@example.com", in: rules)?.name, "win")
        XCTAssertNil(MailRule.firstMatch(for: mail, accountEmail: "none@x.io", in: rules))
    }

    func testRuleCodableRoundTrip() throws {
        let rules = [MailRule(name: "a", accountEmail: "me@x.io", field: .from, keyword: "k", action: .move(path: "Work/&vPQ-")),
                     MailRule(name: "b", accountEmail: "me@x.io", field: .any, keyword: "k", action: .trash)]
        let decoded = try JSONDecoder().decode([MailRule].self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(decoded, rules)
    }

    func testReplyMessageIsMarkedAutomatic() throws {
        let settings = AutoReplySettings(isEnabled: true, subject: "부재중", body: "돌아와서 답장드리겠습니다.")
        let source = envelope(replyTo: ["assistant@corp.io"], subject: "회의 요청")
        let reply = try XCTUnwrap(AutoReplyPolicy.reply(to: source, settings: settings, from: Address(name: nil, email: me)))
        XCTAssertEqual(reply.to.map(\.email), ["assistant@corp.io"])
        XCTAssertEqual(reply.subject, "부재중: 회의 요청")
        XCTAssertEqual(reply.inReplyTo, "<m1@corp.io>")
        let raw = MIMEEntity(MessageBuilder.build(reply))
        XCTAssertEqual(raw.headers["auto-submitted"], "auto-replied")
        XCTAssertEqual(raw.headers["x-auto-response-suppress"], "All")
        XCTAssertEqual(ParsedMessage.parse(MessageBuilder.build(reply)).text, "돌아와서 답장드리겠습니다.")
        // 일반 메일에는 자동 응답 표시가 붙지 않는다.
        let normal = OutgoingMessage(from: reply.from, to: reply.to, cc: [], subject: "s", body: "b")
        XCTAssertNil(MIMEEntity(MessageBuilder.build(normal)).headers["auto-submitted"])
    }
}
