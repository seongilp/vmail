import XCTest
@testable import MailCore

final class ConversationTests: XCTestCase {
    private func envelope(_ uid: UInt32, _ subject: String, id: String? = nil, reply: String? = nil, thread: String? = nil) -> Envelope {
        Envelope(uid: uid, flags: [], date: Date(timeIntervalSince1970: TimeInterval(uid)), size: 0, subject: subject,
                 from: [], to: [], cc: [], replyTo: [], messageID: id, inReplyTo: reply, threadID: thread)
    }

    func testNormalizedSubject() {
        XCTAssertEqual(ThreadGrouper.normalizedSubject("Re: RE: Fwd: 회의 일정").subject, "회의 일정")
        XCTAssertTrue(ThreadGrouper.normalizedSubject("re[2]: Hello").hadPrefix)
        XCTAssertEqual(ThreadGrouper.normalizedSubject("답장: 전달: 보고서").subject, "보고서")
        XCTAssertFalse(ThreadGrouper.normalizedSubject("Report: Q3").hadPrefix)
        XCTAssertEqual(ThreadGrouper.normalizedSubject("Report: Q3").subject, "report: q3")
    }

    func testGroupsByReplyHeaderAndSubject() {
        let groups = ThreadGrouper.group([
            envelope(1, "회의 일정", id: "<a>"),
            envelope(2, "다른 이야기", id: "<b>"),
            envelope(3, "완전히 바뀐 제목", id: "<c>", reply: "<a>"),   // 헤더로 연결
            envelope(4, "Re: 다른 이야기", id: "<d>"),                // 제목으로 연결
            envelope(5, "주간 뉴스", id: "<e>"),
            envelope(6, "주간 뉴스", id: "<f>"),                     // 답장 표시가 없으면 묶지 않는다
        ])
        XCTAssertEqual(groups.map { $0.map(\.uid) }, [[6], [5], [4, 2], [3, 1]])
    }

    func testServerThreadIDWinsOverSubject() {
        let groups = ThreadGrouper.group([
            envelope(1, "Re: 같은 제목", thread: "100"),
            envelope(2, "Re: 같은 제목", thread: "200"),
            envelope(3, "전혀 다른 제목", thread: "100"),
        ])
        XCTAssertEqual(groups.map { $0.map(\.uid) }, [[3, 1], [2]])
        XCTAssertEqual(ThreadGrouper.group([]).count, 0)
    }

    func testBodyStructurePicksPlainTextPart() throws {
        let single = try IMAPParser.parse(Data(#"("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "BASE64" 120 3)"#.utf8))[0]
        XCTAssertEqual(BodyStructure.previewPart(single),
                       PreviewPart(section: "1", encoding: "base64", charset: "utf-8", isHTML: false))

        let nested = try IMAPParser.parse(Data((#"((("TEXT" "HTML" ("CHARSET" "euc-kr") NIL NIL "QUOTED-PRINTABLE" 10 1)"#
            + #"("TEXT" "PLAIN" ("CHARSET" "euc-kr") NIL NIL "7BIT" 10 1) "ALTERNATIVE")"#
            + #"("APPLICATION" "PDF" NIL NIL NIL "BASE64" 999) "MIXED")"#).utf8))[0]
        XCTAssertEqual(BodyStructure.previewPart(nested)?.section, "1.2")

        let htmlOnly = try IMAPParser.parse(Data(#"(("TEXT" "HTML" NIL NIL NIL "7BIT" 10 1)("IMAGE" "PNG" NIL NIL NIL "BASE64" 5) "RELATED")"#.utf8))[0]
        XCTAssertEqual(BodyStructure.previewPart(htmlOnly), PreviewPart(section: "1", encoding: "7bit", charset: nil, isHTML: true))

        let noText = try IMAPParser.parse(Data(#"("IMAGE" "PNG" NIL NIL NIL "BASE64" 5)"#.utf8))[0]
        XCTAssertNil(BodyStructure.previewPart(noText))
    }

    func testPreviewTextFromTruncatedParts() {
        let plain = PreviewPart(section: "1", encoding: "7bit", charset: "utf-8", isHTML: false)
        XCTAssertEqual(PreviewText.make(Data("안녕하세요.\r\n\r\n> 인용문은 뺀다\r\n내일   뵙겠습니다.".utf8), part: plain),
                       "안녕하세요. 내일 뵙겠습니다.")

        // base64가 4의 배수가 아닌 곳에서 잘리고, 한글이 글자 중간에서 끊긴 경우
        let encoded = Data("가나다라마바사".utf8).base64EncodedString()
        let cut = Data(encoded.prefix(encoded.count - 3).utf8)
        let base64 = PreviewPart(section: "1", encoding: "base64", charset: "utf-8", isHTML: false)
        let text = PreviewText.make(cut, part: base64)
        XCTAssertTrue(text.hasPrefix("가나다라"))
        XCTAssertFalse(text.contains("\u{FFFD}"))

        let html = PreviewPart(section: "1", encoding: "quoted-printable", charset: "utf-8", isHTML: true)
        XCTAssertEqual(PreviewText.make(Data("<html><head><style>p{color:red}</style></head><body><p>Hi =\r\nthere</p><div cla".utf8), part: html),
                       "Hi there")
        XCTAssertEqual(PreviewText.make(Data("<style>body { margin: 0".utf8), part: html), "")
        XCTAssertEqual(PreviewText.make(Data(String(repeating: "가", count: 500).utf8), part: plain).count, PreviewText.maxLength)
    }
}
