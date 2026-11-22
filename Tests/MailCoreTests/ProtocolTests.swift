import XCTest
@testable import MailCore

/// 로컬 가짜 서버를 상대로 IMAP/SMTP 클라이언트의 실제 소켓 왕복을 검증한다.
final class ProtocolTests: XCTestCase {
    private static let rawMessage = "Subject: hi\r\nContent-Type: text/plain\r\n\r\nhello {3}\r\nworld"

    private func imapServer() throws -> FakeServer {
        try FakeServer(greeting: "* OK fake ready\r\n") { line, state in
            if let tag = state["searchTag"] {
                state["searchTag"] = nil
                state["searched"] = line
                return Data("* SEARCH 10 11\r\n\(tag) OK done\r\n".utf8)
            }
            // APPEND 리터럴 본문 수신 중
            if let tag = state["appendTag"] {
                if line.isEmpty {
                    state["appendTag"] = nil
                    return Data("\(tag) OK APPEND completed\r\n".utf8)
                }
                return Data()
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return Data() }
            let tag = parts[0]
            let command = parts[1]
            func ok(_ untagged: String = "") -> Data { Data("\(untagged)\(tag) OK done\r\n".utf8) }

            if command.hasPrefix("LOGIN") {
                return command == "LOGIN \"user\" \"p\\\"w\"" ? ok() : Data("\(tag) NO [AUTHENTICATIONFAILED] bad\r\n".utf8)
            }
            if command == "CAPABILITY" { return ok("* CAPABILITY IMAP4rev1 MOVE UIDPLUS\r\n") }
            if command.hasPrefix("LIST") {
                return ok("* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n"
                    + "* LIST (\\Noselect) \"/\" \"[Gmail]\"\r\n"
                    + "* LIST (\\Trash) \"/\" \"[Gmail]/Trash\"\r\n")
            }
            if command.hasPrefix("SELECT") {
                return ok("* 2 EXISTS\r\n* OK [UIDVALIDITY 77] valid\r\n")
            }
            if command.hasPrefix("STATUS") { return ok("* STATUS \"INBOX\" (UNSEEN 5)\r\n") }
            if command.hasPrefix("FETCH 1:2") {
                func row(_ seq: Int, _ uid: Int, _ flags: String) -> String {
                    "* \(seq) FETCH (UID \(uid) FLAGS (\(flags)) INTERNALDATE \"17-Nov-2026 09:30:00 +0900\" RFC822.SIZE 10 "
                        + "ENVELOPE (NIL {\(3)}\r\nabc ((\"A\" NIL \"a\" \"x.io\")) NIL NIL NIL NIL NIL NIL \"<\(uid)@x.io>\"))\r\n"
                }
                return ok(row(1, 10, "\\Seen") + row(2, 11, ""))
            }
            if command.hasPrefix("UID FETCH 11 ") {
                let raw = ProtocolTests.rawMessage
                return ok("* 2 FETCH (UID 11 BODY[] {\(raw.utf8.count)}\r\n\(raw))\r\n")
            }
            if command.hasPrefix("UID FETCH 99") { return ok() }
            if command.hasPrefix("UID FETCH 12 (BODY.PEEK[HEADER.FIELDS") {
                let head = "List-Id: <dev.example.com>\r\nPrecedence: bulk\r\n\r\n"
                return ok("* 3 FETCH (UID 12 BODY[HEADER.FIELDS (LIST-ID PRECEDENCE)] {\(head.utf8.count)}\r\n\(head))\r\n")
            }
            if command.hasPrefix("UID FETCH 11,10") {
                return ok("* 2 FETCH (UID 11 FLAGS () INTERNALDATE \"17-Nov-2026 09:30:00 +0900\" RFC822.SIZE 1 "
                    + "ENVELOPE (NIL \"hit\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n")
            }
            if command.hasPrefix("UID SEARCH") {
                state["searchTag"] = tag
                return Data("+ go ahead\r\n".utf8)
            }
            if command.hasPrefix("APPEND") {
                state["appendTag"] = tag
                return Data("+ go ahead\r\n".utf8)
            }
            return ok()
        }
    }

    private func connectedClient(_ server: FakeServer) throws -> IMAPClient {
        let client = IMAPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5)
        try client.connect()
        try client.login(user: "user", password: "p\"w")
        return client
    }

    func testIMAPSessionRoundTrip() throws {
        let server = try imapServer()
        defer { server.stop() }
        let client = try connectedClient(server)

        let mailboxes = try client.listMailboxes()
        XCTAssertEqual(mailboxes.map(\.path), ["INBOX", "[Gmail]/Trash"])
        XCTAssertEqual(mailboxes.map(\.role), [.inbox, .trash])

        XCTAssertEqual(try client.select("INBOX"), MailboxStatus(exists: 2, uidValidity: 77))
        XCTAssertEqual(client.selectedPath, "INBOX")
        XCTAssertEqual(try client.unseenCount("INBOX"), 5)

        let envelopes = try client.fetchEnvelopes(1...2)
        XCTAssertEqual(envelopes.map(\.uid), [11, 10])
        XCTAssertEqual(envelopes.map(\.subject), ["abc", "abc"])
        XCTAssertEqual(envelopes.map(\.isSeen), [false, true])
        XCTAssertEqual(envelopes.first?.from.first, Address(name: "A", email: "a@x.io"))

        let body = try client.fetchBody(uid: 11)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), Self.rawMessage)
        XCTAssertEqual(ParsedMessage.parse(body).text, "hello {3}\r\nworld")
        XCTAssertThrowsError(try client.fetchBody(uid: 99))

        try client.store(uids: [10, 11], flag: "\\Seen", add: true)
        try client.move(uids: [10], to: "[Gmail]/Trash")
        try client.deletePermanently(uids: [11])
        try client.append(to: "Sent", message: Data("A: b\r\n\r\nbody".utf8))
        let headers = try client.fetchHeaders(uid: 12, fields: ["LIST-ID", "PRECEDENCE"])
        XCTAssertEqual(headers["list-id"], "<dev.example.com>")
        XCTAssertEqual(headers["precedence"], "bulk")
        XCTAssertNil(try client.fetchHeaders(uid: 99, fields: ["LIST-ID"])["list-id"])
        XCTAssertEqual(try client.search(text: "회의"), [11, 10])
        XCTAssertEqual(try client.fetchEnvelopes(uids: [11, 10]).map(\.subject), ["hit"])
        XCTAssertEqual(try client.fetchEnvelopes(uids: []), [])
        try client.createMailbox("New")
        try client.renameMailbox("New", to: "Newer")
        try client.deleteMailbox("INBOX")
        XCTAssertNil(client.selectedPath)
        try client.select("INBOX")
        try client.storeAll(flag: "\\Seen")
        try client.expungeAll()
        client.logout()

        let lines = server.lines()
        XCTAssertTrue(lines.contains { $0.hasSuffix("STORE 1:* +FLAGS.SILENT (\\Seen)") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("STORE 1:* +FLAGS.SILENT (\\Deleted)") })
        XCTAssertTrue(lines.contains { $0.hasSuffix(" EXPUNGE") })
        XCTAssertTrue(lines.contains("회의"))
        XCTAssertTrue(lines.contains { $0.hasSuffix("RENAME \"New\" \"Newer\"") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("DELETE \"INBOX\"") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("UID STORE 10,11 +FLAGS.SILENT (\\Seen)") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("UID MOVE 10 \"[Gmail]/Trash\"") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("UID EXPUNGE 11") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("APPEND \"Sent\" (\\Seen) {12}") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("LOGOUT") })
    }

    func testIMAPLoginFailureIsAuthError() throws {
        let server = try imapServer()
        defer { server.stop() }
        let client = IMAPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5)
        try client.connect()
        XCTAssertThrowsError(try client.login(user: "user", password: "wrong")) { error in
            guard case MailError.auth = error else { return XCTFail("auth 오류여야 함: \(error)") }
        }
    }

    func testConnectionRefusedIsConnectionError() {
        let client = IMAPClient(host: "127.0.0.1", port: 1, security: .none, timeout: 5)
        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertEqual((error as? MailError)?.isConnectionFailure, true)
        }
    }

    func testSessionReportsFailureOnMainQueue() {
        // 닫힌 포트: 재시도 후에도 실패가 메인 큐로 전달되어야 한다.
        let account = Account(displayName: "", email: "user@x.io", username: "user",
                              imapHost: "127.0.0.1", imapPort: 1, smtpHost: "127.0.0.1", smtpPort: 1)
        let session = MailSession(account: account, password: "pw")
        let listed = expectation(description: "perform")
        session.perform({ try $0.listMailboxes() }) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure(let error) = result {
                XCTAssertEqual((error as? MailError)?.isConnectionFailure, true)
            } else {
                XCTFail("닫힌 포트 접속은 실패해야 한다")
            }
            listed.fulfill()
        }
        let sent = expectation(description: "send")
        let message = OutgoingMessage(from: account.address, to: [Address(name: nil, email: "a@x.io")], cc: [],
                                      subject: "s", body: "b")
        session.send(message, sentMailbox: nil) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("닫힌 포트 발송은 실패해야 한다") }
            sent.fulfill()
        }
        let verified = expectation(description: "verify")
        MailSession.verify(account: account, password: "pw") { result in
            if case .success = result { XCTFail("닫힌 포트 검증은 실패해야 한다") }
            verified.fulfill()
        }
        wait(for: [listed, sent, verified], timeout: 20)
        session.disconnect()
    }

    func testSMTPSend() throws {
        let server = try FakeServer(greeting: "220 fake ESMTP\r\n") { line, state in
            if state["data"] != nil {
                if line == "." {
                    state["data"] = nil
                    return Data("250 queued\r\n".utf8)
                }
                state["body", default: ""] += line + "\n"
                return Data()
            }
            if line.hasPrefix("EHLO") { return Data("250-fake\r\n250-AUTH LOGIN PLAIN\r\n250 SIZE 100\r\n".utf8) }
            if line.hasPrefix("AUTH PLAIN") {
                let expected = Data("\u{0}user\u{0}pw".utf8).base64EncodedString()
                return Data((line == "AUTH PLAIN \(expected)" ? "235 ok\r\n" : "535 bad credentials\r\n").utf8)
            }
            if line.hasPrefix("RCPT TO:<bad@") { return Data("550 no such user\r\n".utf8) }
            if line.hasPrefix("MAIL FROM") || line.hasPrefix("RCPT TO") { return Data("250 ok\r\n".utf8) }
            if line == "DATA" {
                state["data"] = "1"
                return Data("354 go\r\n".utf8)
            }
            if line == "QUIT" { return Data("221 bye\r\n".utf8) }
            return Data("500 unknown\r\n".utf8)
        }
        defer { server.stop() }

        func client() -> SMTPClient { SMTPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5) }
        let message = Data("Subject: x\r\n\r\n.dot line\r\nend\r\n".utf8)

        try client().send(username: "user", password: "pw", from: "me@x.io", recipients: ["a@x.io", "b@x.io"], message: message)
        let lines = server.lines()
        XCTAssertTrue(lines.contains("MAIL FROM:<me@x.io>"))
        XCTAssertTrue(lines.contains("RCPT TO:<b@x.io>"))
        XCTAssertTrue(lines.contains("..dot line"))
        XCTAssertTrue(lines.contains("QUIT"))

        XCTAssertThrowsError(try client().send(username: "user", password: "nope", from: "me@x.io",
                                               recipients: ["a@x.io"], message: message)) { error in
            guard case MailError.auth = error else { return XCTFail("auth 오류여야 함: \(error)") }
        }
        XCTAssertThrowsError(try client().send(username: "user", password: "pw", from: "me@x.io",
                                               recipients: ["bad@x.io"], message: message)) { error in
            guard case MailError.server = error else { return XCTFail("server 오류여야 함: \(error)") }
        }
    }

    /// 실제 서버와의 TLS/STARTTLS 핸드셰이크 확인 (자격증명 불필요). VMAIL_NET=1 일 때만 실행.
    func testLiveTLSHandshake() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VMAIL_NET"] == "1", "네트워크 테스트 비활성")
        let imap = IMAPClient(host: "imap.gmail.com", port: 993, security: .tls, timeout: 15)
        try imap.connect()
        XCTAssertThrowsError(try imap.login(user: "nobody@example.invalid", password: "x")) { error in
            guard case MailError.auth = error else { return XCTFail("auth 오류여야 함: \(error)") }
        }
        imap.close()

        for (host, port, security) in [("smtp.gmail.com", 465, ConnectionSecurity.tls), ("smtp.gmail.com", 587, .startTLS)] {
            let smtp = SMTPClient(host: host, port: port, security: security, timeout: 15)
            XCTAssertThrowsError(try smtp.send(username: "nobody@example.invalid", password: "x", from: "a@example.invalid",
                                               recipients: ["b@example.invalid"], message: Data())) { error in
                guard case MailError.auth = error else { return XCTFail("\(host):\(port) auth 오류여야 함: \(error)") }
            }
        }
    }
}
