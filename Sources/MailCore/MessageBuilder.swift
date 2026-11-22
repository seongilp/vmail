import Foundation

/// 보낼 메시지를 RFC 5322 / MIME 바이트로 조립한다.
public enum MessageBuilder {
    private static let base64Lines: Data.Base64EncodingOptions =
        [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
    private static let emailRegex = try! NSRegularExpression(pattern: "^[^@\\s<>\"]+@[^@\\s<>\"]+\\.[^@\\s<>\"]+$")

    public static func build(_ message: OutgoingMessage, date: Date = Date(),
                             messageID: String? = nil) -> Data {
        let domain = message.from.email.components(separatedBy: "@").last ?? "localhost"
        let id = messageID ?? "<\(UUID().uuidString)@\(domain)>"
        var headers = [
            "From: \(format(message.from))",
            "To: \(message.to.map(format).joined(separator: ", "))",
        ]
        if !message.cc.isEmpty { headers.append("Cc: \(message.cc.map(format).joined(separator: ", "))") }
        headers.append("Subject: \(HeaderCoding.encode(message.subject))")
        headers.append("Date: \(MessageDate.format(date))")
        headers.append("Message-ID: \(id)")
        if let reply = message.inReplyTo, !reply.isEmpty {
            headers.append("In-Reply-To: \(reply)")
            headers.append("References: \(reply)")
        }
        if message.isAutoReply {
            headers.append("Auto-Submitted: auto-replied")
            headers.append("X-Auto-Response-Suppress: All")
        }
        headers.append("MIME-Version: 1.0")

        let textPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + Data(normalizeNewlines(message.body).utf8).base64EncodedString(options: base64Lines) + "\r\n"

        if message.attachments.isEmpty {
            return Data((headers.joined(separator: "\r\n") + "\r\n" + textPart).utf8)
        }

        let boundary = "vmail-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var out = headers.joined(separator: "\r\n") + "\r\n\r\n"
        out += "--\(boundary)\r\n" + textPart
        for attachment in message.attachments {
            let name = HeaderCoding.encode(attachment.filename).replacingOccurrences(of: "\r\n ", with: " ")
            out += "--\(boundary)\r\n"
            out += "Content-Type: \(attachment.mimeType); name=\"\(name)\"\r\n"
            out += "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
            out += "Content-Transfer-Encoding: base64\r\n\r\n"
            out += attachment.data.base64EncodedString(options: base64Lines) + "\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }

    /// "이름 <a@b.c>, d@e.f" → [Address]. 주소가 하나라도 잘못되면 nil.
    public static func parseAddressList(_ text: String) -> [Address]? {
        var result: [Address] = []
        let normalized = text.replacingOccurrences(of: ";", with: ",")
        for raw in MIMEHeaders.splitOutsideQuotes(normalized, separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.isEmpty { continue }
            var name: String?
            var email = entry
            if let open = entry.lastIndex(of: "<"), let close = entry.lastIndex(of: ">"), open < close {
                email = String(entry[entry.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                let label = entry[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                name = label.isEmpty ? nil : label
            }
            guard isValidEmail(email) else { return nil }
            result.append(Address(name: name, email: email))
        }
        return result
    }

    public static func isValidEmail(_ email: String) -> Bool {
        emailRegex.firstMatch(in: email, range: NSRange(email.startIndex..., in: email)) != nil
    }

    static func format(_ address: Address) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        let encoded = HeaderCoding.encode(name)
        let label = encoded == name ? "\"\(name.replacingOccurrences(of: "\"", with: ""))\"" : encoded
        return "\(label) <\(address.email)>"
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }
}
