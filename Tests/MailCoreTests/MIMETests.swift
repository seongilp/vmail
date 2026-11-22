import XCTest
@testable import MailCore

final class MIMETests: XCTestCase {
    private func message(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    func testPlainQuotedPrintableBody() {
        let parsed = ParsedMessage.parse(message([
            "From: =?UTF-8?B?7ZmN6ri464+Z?= <hong@example.com>",
            "Subject: =?UTF-8?B?7JWI64WV?=",
            "Date: Tue, 17 Nov 2026 09:30:00 +0900",
            "Content-Type: text/plain; charset=\"utf-8\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "=EC=95=88=EB=85=95 soft=",
            "break",
        ]))
        XCTAssertEqual(parsed.subject, "안녕")
        XCTAssertEqual(parsed.from, "홍길동 <hong@example.com>")
        XCTAssertEqual(parsed.text, "안녕 softbreak")
        XCTAssertNil(parsed.html)
        XCTAssertNotNil(parsed.date)
    }

    func testMultipartAlternativeWithAttachmentAndInlineImage() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let parsed = ParsedMessage.parse(message([
            "Subject: multi",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "preamble",
            "--outer",
            "Content-Type: multipart/related; boundary=rel",
            "",
            "--rel",
            "Content-Type: multipart/alternative; boundary=alt",
            "",
            "--alt",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "plain body",
            "--alt",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            Data("<p>hi <img src=\"cid:logo@x\"></p>".utf8).base64EncodedString(),
            "--alt--",
            "--rel",
            "Content-Type: image/png",
            "Content-ID: <logo@x>",
            "Content-Transfer-Encoding: base64",
            "",
            png.base64EncodedString(),
            "--rel--",
            "--outer",
            "Content-Type: application/pdf",
            "Content-Disposition: attachment; filename*=UTF-8''%EB%B3%B4%EA%B3%A0%EC%84%9C.pdf",
            "Content-Transfer-Encoding: base64",
            "",
            Data("PDFDATA".utf8).base64EncodedString(),
            "--outer--",
            "epilogue",
        ]))
        XCTAssertEqual(parsed.text, "plain body")
        XCTAssertEqual(parsed.html, "<p>hi <img src=\"data:image/png;base64,\(png.base64EncodedString())\"></p>")
        XCTAssertEqual(parsed.attachments.map(\.filename), ["보고서.pdf"])
        XCTAssertEqual(parsed.attachments.first?.data, Data("PDFDATA".utf8))
    }

    func testMissingClosingBoundaryKeepsLastPart() {
        let parts = TransferCoding.splitMultipart(Data("--b\r\nA: 1\r\n\r\none\r\n--b\r\n\r\ntwo".utf8), boundary: "b")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(decoding: parts[1], as: UTF8.self), "\r\ntwo")
    }

    func testBoundaryTextInsideLineIsNotADelimiter() {
        let parts = TransferCoding.splitMultipart(Data("--b\r\n\r\nsee --b here\r\n--b--".utf8), boundary: "b")
        XCTAssertEqual(parts.map { String(decoding: $0, as: UTF8.self) }, ["\r\nsee --b here"])
    }

    func testParameterContinuationAndEncodedWordFilename() {
        let split = MIMEHeaders.parseParameterized("attachment; filename*0=\"long\"; filename*1=\"name.txt\"")
        XCTAssertEqual(split.params["filename"], "longname.txt")
        let word = MIMEHeaders.parseParameterized("application/zip; name=\"=?UTF-8?B?7JWI64WV?=.zip\"")
        XCTAssertEqual(word.value, "application/zip")
        XCTAssertEqual(word.params["name"], "안녕.zip")
    }

    func testFoldedHeadersAndLFOnlyMessage() {
        let entity = MIMEEntity(Data("Subject: a\n b\nX-Other: y\n\nbody".utf8))
        XCTAssertEqual(entity.headers["subject"], "a b")
        XCTAssertEqual(entity.headers["X-Other"], "y")
        XCTAssertEqual(String(decoding: entity.body, as: UTF8.self), "body")
    }

    func testEUCKRHTMLBody() {
        var raw = Data("Content-Type: text/html; charset=euc-kr\r\n\r\n<b>".utf8)
        raw.append(Data([0xC7, 0xD1, 0xB1, 0xDB]))
        raw.append(Data("</b>".utf8))
        let parsed = ParsedMessage.parse(raw)
        XCTAssertEqual(parsed.html, "<b>한글</b>")
        XCTAssertEqual(parsed.plainText, "한글")
    }

    func testHTMLToPlainText() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;&amp; bye</p><div>next<br>line</div></body></html>"
        XCTAssertEqual(HTMLText.plain(from: html), "Hello & bye\nnext\nline")
        XCTAssertEqual(HTMLText.escape("<a href=\"x\">&</a>"), "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;")
    }

    func testBuilderRoundTrip() {
        let outgoing = OutgoingMessage(
            from: Address(name: "홍길동", email: "hong@example.com"),
            to: [Address(name: nil, email: "a@example.com"), Address(name: "Bob", email: "b@example.com")],
            cc: [Address(name: nil, email: "c@example.com")],
            subject: "회의 일정 안내",
            body: "안녕하세요.\n.점으로 시작하는 줄\n감사합니다.",
            attachments: [Attachment(filename: "메모.txt", mimeType: "text/plain", data: Data("memo".utf8))],
            inReplyTo: "<orig@example.com>"
        )
        let raw = MessageBuilder.build(outgoing, messageID: "<fixed@example.com>")
        let parsed = ParsedMessage.parse(raw)
        XCTAssertEqual(parsed.subject, "회의 일정 안내")
        XCTAssertEqual(parsed.from, "홍길동 <hong@example.com>")
        XCTAssertEqual(parsed.to, "a@example.com, \"Bob\" <b@example.com>")
        XCTAssertEqual(parsed.cc, "c@example.com")
        XCTAssertEqual(parsed.text, "안녕하세요.\r\n.점으로 시작하는 줄\r\n감사합니다.")
        XCTAssertEqual(parsed.attachments.map(\.filename), ["메모.txt"])
        XCTAssertEqual(parsed.attachments.first?.data, Data("memo".utf8))
        XCTAssertEqual(parsed.messageID, "<fixed@example.com>")
        XCTAssertEqual(MIMEEntity(raw).headers["in-reply-to"], "<orig@example.com>")
    }

    func testBccIsNotWrittenToHeaders() {
        let outgoing = OutgoingMessage(from: Address(name: nil, email: "me@x.io"), to: [Address(name: nil, email: "a@x.io")],
                                       cc: [], bcc: [Address(name: nil, email: "secret@x.io")], subject: "s", body: "b")
        let raw = String(decoding: MessageBuilder.build(outgoing), as: UTF8.self)
        XCTAssertFalse(raw.contains("secret@x.io"))
        // Message-ID의 UUID에 우연히 "bcc"가 들어갈 수 있으므로 헤더 줄만 본다.
        XCTAssertNil(MIMEEntity(Data(raw.utf8)).headers["bcc"])
    }

    func testAddressListParsing() {
        XCTAssertEqual(MessageBuilder.parseAddressList("a@b.co, \"Kim, Lee\" <k@b.co>; 홍 <h@b.co>"), [
            Address(name: nil, email: "a@b.co"),
            Address(name: "Kim, Lee", email: "k@b.co"),
            Address(name: "홍", email: "h@b.co"),
        ])
        XCTAssertEqual(MessageBuilder.parseAddressList("  "), [])
        XCTAssertNil(MessageBuilder.parseAddressList("a@b.co, nope"))
        XCTAssertNil(MessageBuilder.parseAddressList("a b@c.d"))
    }

    func testDotStuffing() {
        let stuffed = SMTPClient.dotStuffed(Data(".a\r\n..b\r\nc.\r\n".utf8))
        XCTAssertEqual(String(decoding: stuffed, as: UTF8.self), "..a\r\n...b\r\nc.")
    }

    func testAccountPresets() {
        let gmail = Account.preset(email: "me@gmail.com")
        XCTAssertEqual(gmail.imapHost, "imap.gmail.com")
        XCTAssertEqual(gmail.smtpSecurity, .tls)
        XCTAssertTrue(gmail.serverSavesSentMail)
        let naver = Account.preset(email: "me@naver.com")
        XCTAssertEqual(naver.username, "me")
        let icloud = Account.preset(email: "me@icloud.com")
        XCTAssertEqual(icloud.smtpPort, 587)
        XCTAssertEqual(icloud.smtpSecurity, .startTLS)
        let custom = Account.preset(email: "me@corp.example")
        XCTAssertEqual(custom.imapHost, "imap.corp.example")
        XCTAssertEqual(custom.imapSecurity, .tls)
        XCTAssertFalse(custom.serverSavesSentMail)
        let local = Account(displayName: "", email: "a@b.co", username: "a", imapHost: "127.0.0.1", imapPort: 1143,
                            smtpHost: "localhost", smtpPort: 1025)
        XCTAssertEqual(local.imapSecurity, .none)
        XCTAssertEqual(local.smtpSecurity, .none)
        XCTAssertEqual(Account.preset(email: "").imapHost, "")
    }
}
