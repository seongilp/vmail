import XCTest
@testable import MailCore

final class CodingTests: XCTestCase {
    func testDecodesBase64EncodedWord() {
        XCTAssertEqual(HeaderCoding.decode("=?UTF-8?B?7JWI64WV7ZWY7IS47JqU?="), "안녕하세요")
    }

    func testDecodesQEncodedWordWithUnderscore() {
        XCTAssertEqual(HeaderCoding.decode("=?utf-8?Q?Caf=C3=A9_au_lait?= today"), "Café au lait today")
    }

    func testDropsWhitespaceBetweenAdjacentWords() {
        XCTAssertEqual(HeaderCoding.decode("=?UTF-8?B?7JWI64WV?= =?UTF-8?B?7ZWY7IS47JqU?="), "안녕하세요")
    }

    func testJoinsMultibyteCharacterSplitAcrossWords() {
        // "안"(EC 95 88)을 두 단어로 쪼갠 경우
        let first = Data([0xEC, 0x95]).base64EncodedString()
        let second = Data([0x88]).base64EncodedString()
        XCTAssertEqual(HeaderCoding.decode("=?UTF-8?B?\(first)?= =?UTF-8?B?\(second)?="), "안")
    }

    func testDecodesEUCKR() {
        // "한글" in EUC-KR
        let word = Data([0xC7, 0xD1, 0xB1, 0xDB]).base64EncodedString()
        XCTAssertEqual(HeaderCoding.decode("=?ks_c_5601-1987?B?\(word)?="), "한글")
        XCTAssertEqual(HeaderCoding.decode("=?EUC-KR?B?\(word)?="), "한글")
    }

    func testLeavesPlainTextAlone() {
        XCTAssertEqual(HeaderCoding.decode("Hello =? world"), "Hello =? world")
    }

    func testEncodeRoundTripsLongKoreanSubject() {
        let subject = String(repeating: "아주 긴 제목입니다 ", count: 12)
        let encoded = HeaderCoding.encode(subject)
        XCTAssertTrue(encoded.components(separatedBy: "\r\n ").allSatisfy { $0.count <= 75 })
        XCTAssertEqual(HeaderCoding.decode(encoded), subject)
    }

    func testEncodeKeepsASCII() {
        XCTAssertEqual(HeaderCoding.encode("Hello, world"), "Hello, world")
    }

    func testModifiedUTF7() {
        XCTAssertEqual(ModifiedUTF7.decode("INBOX"), "INBOX")
        XCTAssertEqual(ModifiedUTF7.decode("A &- B"), "A & B")
        XCTAssertEqual(ModifiedUTF7.decode("[Gmail]/&yATMtLz0rQDVaA-"), "[Gmail]/전체보관함")
    }

    func testCharsetFallsBackWhenDeclaredCharsetIsWrong() {
        XCTAssertEqual(Charset.decode(Data("한글".utf8), charset: "x-unknown"), "한글")
        XCTAssertEqual(Charset.decode(Data([0xC7, 0xD1, 0xB1, 0xDB]), charset: nil), "한글")
    }

    func testAppPasswordNormalization() {
        XCTAssertEqual(AppPassword.normalize(" abcd efgh ijkl mnop\n"), "abcdefghijklmnop")
        XCTAssertEqual(AppPassword.normalize("abcdefghijklmnop"), "abcdefghijklmnop")
        XCTAssertEqual(AppPassword.normalize("abcd-efgh-ijkl-mnop"), "abcd-efgh-ijkl-mnop")
        XCTAssertNil(AppPassword.normalize("hello world"))
        XCTAssertNil(AppPassword.normalize("abcd efgh ijkl mno1"))
        XCTAssertNil(AppPassword.normalize("ABCD EFGH IJKL MNOP"))
        XCTAssertNil(AppPassword.normalize(""))
    }

    func testMessageDate() {
        let date = MessageDate.parse("Tue, 17 Nov 2026 09:30:00 +0900 (KST)")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_794_875_400))
        XCTAssertNil(MessageDate.parse("not a date"))
    }
}
