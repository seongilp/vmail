import Foundation

/// 메시지 한 통을 보내고 끊는 동기식 SMTP 클라이언트. 백그라운드 큐에서만 사용한다.
public final class SMTPClient {
    private let connection: LineConnection
    private let security: ConnectionSecurity

    public init(host: String, port: Int, security: ConnectionSecurity, timeout: TimeInterval = 30) {
        connection = LineConnection(host: host, port: port, timeout: timeout)
        self.security = security
    }

    public func send(username: String, password: String, from: String, recipients: [String], message: Data) throws {
        defer { connection.close() }
        try connection.open(security: security)
        try expect(220, try readReply())

        var features = try ehlo()
        if security == .startTLS {
            try expect(220, try command("STARTTLS"))
            try connection.startTLS()
            features = try ehlo()
        }
        try authenticate(username: username, password: password, features: features)

        try expect(250, try command("MAIL FROM:<\(from)>"))
        for recipient in recipients {
            let reply = try command("RCPT TO:<\(recipient)>")
            guard reply.code == 250 || reply.code == 251 else {
                throw MailError.server("받는 사람 \(recipient) 을(를) 서버가 거부했습니다. \(reply.text)")
            }
        }
        try expect(354, try command("DATA"))
        try connection.write(Self.dotStuffed(message) + Data("\r\n.\r\n".utf8))
        try expect(250, try readReply())
        _ = try? command("QUIT")
    }

    // MARK: - Private

    private struct Reply {
        let code: Int
        let text: String
    }

    private func ehlo() throws -> String {
        let reply = try command("EHLO localhost")
        try expect(250, reply)
        return reply.text.uppercased()
    }

    private func authenticate(username: String, password: String, features: String) throws {
        let authLine = features.components(separatedBy: "\n").first { $0.hasPrefix("AUTH") } ?? ""
        let reply: Reply
        if authLine.contains("PLAIN") || !authLine.contains("LOGIN") {
            let token = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
            reply = try command("AUTH PLAIN \(token)")
        } else {
            try expect(334, try command("AUTH LOGIN"))
            try expect(334, try command(Data(username.utf8).base64EncodedString()))
            reply = try command(Data(password.utf8).base64EncodedString())
        }
        guard reply.code == 235 else { throw MailError.auth(reply.text) }
    }

    private func command(_ line: String) throws -> Reply {
        try connection.write(line + "\r\n")
        return try readReply()
    }

    /// "250-..." 연속 줄을 "250 ..." 까지 모아 읽는다.
    private func readReply() throws -> Reply {
        var lines: [String] = []
        while true {
            let line = String(decoding: try connection.readLine(), as: UTF8.self)
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw MailError.malformed("SMTP 응답: \(line)")
            }
            lines.append(String(line.dropFirst(4)))
            let isLast = line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-"
            if isLast { return Reply(code: code, text: lines.joined(separator: "\n")) }
        }
    }

    private func expect(_ code: Int, _ reply: Reply) throws {
        guard reply.code == code else { throw MailError.server(reply.text) }
    }

    /// 줄 맨 앞의 "." 을 ".." 로 바꾼다 (RFC 5321 4.5.2). 끝의 CRLF는 떼어 낸다.
    static func dotStuffed(_ message: Data) -> Data {
        var body = message
        while body.last == 0x0A || body.last == 0x0D { body.removeLast() }
        var out = Data(capacity: body.count + 16)
        var atLineStart = true
        for byte in body {
            if atLineStart, byte == UInt8(ascii: ".") { out.append(byte) }
            out.append(byte)
            atLineStart = byte == 0x0A
        }
        return out
    }
}
