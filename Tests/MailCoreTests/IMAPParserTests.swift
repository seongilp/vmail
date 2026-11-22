import XCTest
@testable import MailCore

final class IMAPParserTests: XCTestCase {
    func testParsesAtomsStringsListsAndNil() throws {
        let values = try IMAPParser.parse(Data(#"12 FETCH (UID 7 FLAGS (\Seen \Flagged) X NIL "a \"q\" b")"#.utf8))
        XCTAssertEqual(values[0], .atom("12"))
        XCTAssertEqual(values[2].listValue?[3], .list([.atom("\\Seen"), .atom("\\Flagged")]))
        XCTAssertEqual(values[2].listValue?[5], .null)
        XCTAssertEqual(values[2].listValue?[6].stringValue, #"a "q" b"#)
    }

    func testParsesLiteral() throws {
        let values = try IMAPParser.parse(Data("1 FETCH (BODY[] {5}\r\nhe(lo UID 3)".utf8))
        let items = try XCTUnwrap(values[2].listValue)
        XCTAssertEqual(items[0], .atom("BODY[]"))
        XCTAssertEqual(items[1], .string(Data("he(lo".utf8)))
        XCTAssertEqual(items[3], .atom("3"))
    }

    func testBracketedAtomKeepsInnerSpaces() throws {
        let values = try IMAPParser.parse(Data("BODY[HEADER.FIELDS (FROM TO)] x".utf8))
        XCTAssertEqual(values, [.atom("BODY[HEADER.FIELDS (FROM TO)]"), .atom("x")])
    }

    func testThrowsOnUnbalancedInput() {
        XCTAssertThrowsError(try IMAPParser.parse(Data("(a b".utf8)))
        XCTAssertThrowsError(try IMAPParser.parse(Data("a) b".utf8)))
        XCTAssertThrowsError(try IMAPParser.parse(Data("\"open".utf8)))
        XCTAssertThrowsError(try IMAPParser.parse(Data("{10}\r\nshort".utf8)))
    }

    func testTrailingLiteralLength() {
        XCTAssertEqual(IMAPClient.trailingLiteralLength(Data("* 1 FETCH (BODY[] {42}".utf8)), 42)
        XCTAssertNil(IMAPClient.trailingLiteralLength(Data("* OK done".utf8)))
        XCTAssertNil(IMAPClient.trailingLiteralLength(Data("* OK {abc}".utf8)))
    }

    func testParsesListLine() throws {
        let line = Data(#"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/&vPSwuNO4ycDVaA-""#.utf8)
        let mailbox = try XCTUnwrap(IMAPClient.parseListLine(line))
        XCTAssertEqual(mailbox.name, "[Gmail]/보낸편지함")
        XCTAssertEqual(mailbox.role, .sent)
        XCTAssertEqual(mailbox.leafName, "보낸편지함")
        XCTAssertTrue(mailbox.isSelectable)
    }

    func testMailboxRoles() {
        func role(_ path: String, _ attrs: [String] = []) -> MailboxRole {
            Mailbox(path: path, name: path, delimiter: "/", attributes: attrs).role
        }
        XCTAssertEqual(role("inbox"), .inbox)
        XCTAssertEqual(role("Deleted Messages"), .trash)
        XCTAssertEqual(role("Sent Messages"), .sent)
        XCTAssertEqual(role("x", ["\\Junk"]), .junk)
        XCTAssertEqual(role("x", ["\\All"]), .all)
        XCTAssertEqual(role("Projects/vmail"), .other)
        XCTAssertFalse(Mailbox(path: "[Gmail]", name: "[Gmail]", delimiter: "/", attributes: ["\\Noselect"]).isSelectable)
    }

    func testDuplicateRolesKeepAttributeConfirmedMailbox() {
        let list = [
            Mailbox(path: "Drafts", name: "Drafts", delimiter: "/", attributes: []),
            Mailbox(path: "[Gmail]/Drafts", name: "[Gmail]/Drafts", delimiter: "/", attributes: ["\\Drafts"]),
            Mailbox(path: "Sent", name: "Sent", delimiter: "/", attributes: []),
            Mailbox(path: "Sent Messages", name: "Sent Messages", delimiter: "/", attributes: []),
            Mailbox(path: "[Gmail]/Important", name: "[Gmail]/Important", delimiter: "/", attributes: ["\\Important"]),
        ]
        let resolved = Mailbox.resolvingDuplicateRoles(list)
        XCTAssertEqual(resolved.map(\.role), [.other, .drafts, .sent, .other, .important])
        XCTAssertEqual(resolved.map(\.path), list.map(\.path))
    }

    func testParsesEnvelopeFromFetchLine() throws {
        let line = Data((#"* 3 FETCH (UID 101 FLAGS (\Seen) INTERNALDATE "17-Nov-2026 09:30:00 +0900" RFC822.SIZE 2048 "#
            + #"ENVELOPE ("Tue, 17 Nov 2026 09:30:00 +0900" "=?UTF-8?B?7JWI64WV?=" (("=?UTF-8?B?7ZmN6ri464+Z?=" NIL "hong" "example.com")) "#
            + #"NIL NIL ((NIL NIL "me" "example.com")) NIL NIL NIL "<id-1@example.com>"))"#).utf8)
        let items = try XCTUnwrap(IMAPClient.parseFetchLine(line))
        let envelope = try XCTUnwrap(EnvelopeParser.envelope(items))
        XCTAssertEqual(envelope.uid, 101)
        XCTAssertEqual(envelope.subject, "안녕")
        XCTAssertEqual(envelope.from, [Address(name: "홍길동", email: "hong@example.com")])
        XCTAssertEqual(envelope.to.first?.email, "me@example.com")
        XCTAssertTrue(envelope.isSeen)
        XCTAssertFalse(envelope.isFlagged)
        XCTAssertEqual(envelope.size, 2048)
        XCTAssertEqual(envelope.date, Date(timeIntervalSince1970: 1_794_875_400))
        XCTAssertEqual(envelope.messageID, "<id-1@example.com>")
    }

    func testEnvelopeFlagUpdateReturnsNewValue() {
        let base = Envelope(uid: 1, flags: [], date: Date(), size: 0, subject: "", from: [], to: [], cc: [],
                            replyTo: [], messageID: nil)
        let seen = base.settingFlag("\\Seen", true)
        XCTAssertFalse(base.isSeen)
        XCTAssertTrue(seen.isSeen)
        XCTAssertFalse(seen.settingFlag("\\seen", false).isSeen)
    }

    func testIgnoresNonFetchLines() {
        XCTAssertNil(IMAPClient.parseFetchLine(Data("* 23 EXISTS".utf8)))
        XCTAssertNil(IMAPClient.parseListLine(Data("* OK hello".utf8)))
    }
}
