import Foundation

/// 화면에 보여줄 수 있게 해석한 메시지
public struct ParsedMessage: Sendable {
    public let subject: String
    public let from: String
    public let to: String
    public let cc: String
    public let date: Date?
    public let messageID: String?
    public let html: String?
    public let text: String?
    public let attachments: [Attachment]

    public static func parse(_ raw: Data) -> ParsedMessage {
        let root = MIMEEntity(raw)
        var collector = Collector()
        collector.walk(root)
        let (html, attachments) = embedInlineImages(html: collector.html, attachments: collector.attachments)
        return ParsedMessage(
            subject: header(root, "subject"),
            from: header(root, "from"),
            to: header(root, "to"),
            cc: header(root, "cc"),
            date: root.headers["date"].flatMap(MessageDate.parse),
            messageID: root.headers["message-id"],
            html: html,
            text: collector.text,
            attachments: attachments
        )
    }

    /// 답장 인용 등에 쓰는 평문 본문
    public var plainText: String {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        if let html { return HTMLText.plain(from: html) }
        return ""
    }

    private static func header(_ entity: MIMEEntity, _ name: String) -> String {
        HeaderCoding.decode(entity.headers[name] ?? "")
    }

    /// HTML이 cid: 로 참조하는 인라인 이미지를 data URI로 바꾸고 첨부 목록에서 뺀다.
    private static func embedInlineImages(html: String?, attachments: [Attachment]) -> (String?, [Attachment]) {
        guard var html else { return (nil, attachments) }
        var remaining: [Attachment] = []
        for attachment in attachments {
            guard let cid = attachment.contentID, html.contains("cid:\(cid)") else {
                remaining.append(attachment)
                continue
            }
            let uri = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            html = html.replacingOccurrences(of: "cid:\(cid)", with: uri)
        }
        return (html, remaining)
    }

    private struct Collector {
        var html: String?
        var text: String?
        var attachments: [Attachment] = []

        mutating func walk(_ entity: MIMEEntity) {
            let type = entity.contentType
            if type.value.hasPrefix("multipart/") {
                for part in entity.parts { walk(part) }
                return
            }
            let disposition = entity.headers.parameterized("content-disposition")
            let filename = disposition?.params["filename"] ?? type.params["name"]
            let isAttachment = disposition?.value == "attachment" || (filename != nil && !type.value.hasPrefix("text/"))

            if type.value == "text/html", !isAttachment, html == nil {
                html = Charset.decode(entity.decodedBody, charset: type.params["charset"])
            } else if type.value == "text/plain", !isAttachment, text == nil {
                text = Charset.decode(entity.decodedBody, charset: type.params["charset"])
            } else {
                let data = type.value == "message/rfc822" ? entity.body : entity.decodedBody
                guard !data.isEmpty else { return }
                let contentID = entity.headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                attachments.append(Attachment(
                    filename: filename ?? Self.defaultName(for: type.value),
                    mimeType: type.value,
                    data: data,
                    contentID: contentID
                ))
            }
        }

        static func defaultName(for mimeType: String) -> String {
            switch mimeType {
            case "message/rfc822": return "메시지.eml"
            case "text/calendar": return "일정.ics"
            case "text/html": return "첨부.html"
            case "text/plain": return "첨부.txt"
            default:
                let ext = mimeType.components(separatedBy: "/").last ?? "bin"
                return "첨부파일.\(ext)"
            }
        }
    }
}

/// HTML ↔ 평문 간이 변환
public enum HTMLText {
    private static let dropBlocks = try! NSRegularExpression(
        pattern: "<(style|script|head)[^>]*>.*?</\\1>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let lineBreaks = try! NSRegularExpression(
        pattern: "<br\\s*/?>|</p>|</div>|</tr>|</h[1-6]>|</li>", options: .caseInsensitive)
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let blankRuns = try! NSRegularExpression(pattern: "\\n[ \\t]*(\\n[ \\t]*)+")
    private static let entities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
    ]

    public static func plain(from html: String) -> String {
        var text = html.replacingOccurrences(of: "\r\n", with: "\n")
        text = replace(dropBlocks, in: text, with: "")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = replace(lineBreaks, in: text, with: "\n")
        text = replace(tags, in: text, with: "")
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        text = replace(blankRuns, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
