import Foundation

/// 목록 미리보기용으로 가져올 본문 파트
public struct PreviewPart: Equatable, Sendable {
    /// IMAP 파트 번호 ("1", "1.2" 등)
    public let section: String
    public let encoding: String
    public let charset: String?
    public let isHTML: Bool
}

/// BODYSTRUCTURE에서 미리보기에 쓸 첫 텍스트 파트를 찾는다 (text/plain 우선, 없으면 text/html).
public enum BodyStructure {
    public static func previewPart(_ value: IMAPValue) -> PreviewPart? {
        var candidates: [PreviewPart] = []
        collect(value, path: [], into: &candidates)
        return candidates.first { !$0.isHTML } ?? candidates.first
    }

    private static func collect(_ value: IMAPValue, path: [Int], into result: inout [PreviewPart]) {
        guard let items = value.listValue, let first = items.first else { return }
        if first.listValue != nil {
            // multipart: 앞쪽의 리스트들이 하위 파트
            for (index, child) in items.enumerated() {
                guard child.listValue != nil else { break }
                collect(child, path: path + [index + 1], into: &result)
            }
            return
        }
        // 단일 파트: (type subtype (params) id description encoding size ...)
        guard items.count >= 6, first.stringValue?.lowercased() == "text",
              let subtype = items[1].stringValue?.lowercased(), subtype == "plain" || subtype == "html" else { return }
        var charset: String?
        if let params = items[2].listValue {
            var i = 0
            while i + 1 < params.count {
                if params[i].stringValue?.lowercased() == "charset" { charset = params[i + 1].stringValue }
                i += 2
            }
        }
        // 최상위가 단일 파트면 번호는 "1"
        let section = path.isEmpty ? "1" : path.map(String.init).joined(separator: ".")
        result.append(PreviewPart(section: section, encoding: items[5].stringValue?.lowercased() ?? "7bit",
                                  charset: charset, isHTML: subtype == "html"))
    }
}

/// 본문 앞부분(잘려 있을 수 있음)을 목록에 보여줄 한두 줄로 만든다.
public enum PreviewText {
    public static let fetchBytes = 1024
    public static let maxLength = 180

    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    /// 잘린 HTML의 끝에 남은 닫히지 않은 태그·스타일 블록
    private static let danglingTag = try! NSRegularExpression(pattern: "<[^>]*$")
    private static let openBlock = try! NSRegularExpression(
        pattern: "<(style|script|head)[^>]*>(?:(?!</\\1>).)*$", options: [.caseInsensitive, .dotMatchesLineSeparators])

    public static func make(_ data: Data, part: PreviewPart) -> String {
        let decoded: Data
        switch part.encoding {
        case "base64":
            // 잘린 base64는 4의 배수 길이까지만 디코딩할 수 있다.
            let clean = data.filter { $0 != 0x0D && $0 != 0x0A && $0 != 0x20 }
            decoded = Data(base64Encoded: clean.prefix(clean.count - clean.count % 4)) ?? Data()
        case "quoted-printable":
            decoded = TransferCoding.decodeQuotedPrintable(data)
        default:
            decoded = data
        }
        var text = Charset.decode(decoded, charset: part.charset)
        if part.isHTML {
            text = replace(openBlock, in: text, with: "")
            text = replace(danglingTag, in: text, with: "")
            text = HTMLText.plain(from: text)
        }
        // 인용문·줄바꿈을 정리해 한 줄로
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        text = replace(whitespace, in: lines.joined(separator: " "), with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FFFD}")))
        return String(text.prefix(maxLength))
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// 메시지를 대화(스레드)로 묶는다.
public enum ThreadGrouper {
    private static let prefixRegex = try! NSRegularExpression(
        pattern: "^\\s*(re|fw|fwd|답장|회신|전달)\\s*(\\[\\d+\\])?\\s*[:：]\\s*", options: .caseInsensitive)

    /// "Re: Fwd: 제목" → ("제목", 답장·전달 접두어가 있었는지)
    public static func normalizedSubject(_ subject: String) -> (subject: String, hadPrefix: Bool) {
        var text = subject
        var hadPrefix = false
        while let match = prefixRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) {
            text.removeSubrange(range)
            hadPrefix = true
        }
        return (text.trimmingCharacters(in: .whitespaces).lowercased(), hadPrefix)
    }

    /// 대화별로 묶어 돌려준다. 각 대화 안은 최신순, 대화끼리는 가장 최근 메시지 기준 최신순.
    /// 묶는 기준: (1) 서버가 준 대화 ID(Gmail), (2) In-Reply-To ↔ Message-ID, (3) 답장 표시가 있는 같은 제목.
    public static func group(_ envelopes: [Envelope]) -> [[Envelope]] {
        var parent = Array(envelopes.indices)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var byThreadID: [String: Int] = [:]
        var byMessageID: [String: Int] = [:]
        for (index, envelope) in envelopes.enumerated() {
            if let id = envelope.threadID {
                if let other = byThreadID[id] { union(index, other) } else { byThreadID[id] = index }
            }
            if let id = envelope.messageID { byMessageID[id] = index }
        }
        var bySubject: [String: (indices: [Int], hasReply: Bool)] = [:]
        for (index, envelope) in envelopes.enumerated() {
            if let reply = envelope.inReplyTo, let target = byMessageID[reply] { union(index, target) }
            // 서버가 대화 ID를 준 메일은 제목으로 다시 묶지 않는다.
            guard envelope.threadID == nil else { continue }
            let (subject, hadPrefix) = normalizedSubject(envelope.subject)
            guard !subject.isEmpty else { continue }
            let bucket = bySubject[subject] ?? ([], false)
            bySubject[subject] = (bucket.indices + [index], bucket.hasReply || hadPrefix || envelope.inReplyTo != nil)
        }
        for bucket in bySubject.values where bucket.hasReply {
            for index in bucket.indices.dropFirst() { union(index, bucket.indices[0]) }
        }

        var groups: [Int: [Envelope]] = [:]
        for (index, envelope) in envelopes.enumerated() {
            groups[find(index), default: []].append(envelope)
        }
        return groups.values
            .map { $0.sorted { $0.uid > $1.uid } }
            .sorted { ($0.first?.uid ?? 0) > ($1.first?.uid ?? 0) }
    }
}
