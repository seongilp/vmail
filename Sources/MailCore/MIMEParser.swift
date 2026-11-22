import Foundation

/// 헤더 값 "main; key=value; ..." 를 분해한 결과
public struct HeaderValue: Equatable {
    public let value: String
    public let params: [String: String]
}

public struct MIMEHeaders {
    public let fields: [(name: String, value: String)]

    public subscript(_ name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.name == key }?.value
    }

    /// 헤더 블록(바이트)을 펼쳐서(unfold) 필드 목록으로 만든다.
    public static func parse(_ data: Data) -> MIMEHeaders {
        let text = Charset.decode(data, charset: nil)
        var fields: [(String, String)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t", let last = fields.popLast() {
                fields.append((last.0, last.1 + " " + line.trimmingCharacters(in: .whitespaces)))
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields.append((name, value))
            }
        }
        return MIMEHeaders(fields: fields.map { (name: $0.0, value: $0.1) })
    }

    /// Content-Type / Content-Disposition 류의 파라미터 헤더 파싱 (RFC 2231 연속·인코딩 포함)
    public func parameterized(_ name: String) -> HeaderValue? {
        guard let raw = self[name] else { return nil }
        return Self.parseParameterized(raw)
    }

    static func parseParameterized(_ raw: String) -> HeaderValue {
        let segments = splitOutsideQuotes(raw, separator: ";")
        let main = (segments.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // base key → (index, value, encoded)
        var pieces: [String: [(Int, String, Bool)]] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            var encoded = false
            if key.hasSuffix("*") {
                encoded = true
                key = String(key.dropLast())
            }
            var index = 0
            if let star = key.lastIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                index = n
                key = String(key[..<star])
            }
            pieces[key, default: []].append((index, value, encoded))
        }
        var params: [String: String] = [:]
        for (key, parts) in pieces {
            let sorted = parts.sorted { $0.0 < $1.0 }
            if sorted.contains(where: { $0.2 }) {
                params[key] = decodeExtended(sorted.map { $0.1 }.joined())
            } else {
                params[key] = HeaderCoding.decode(sorted.map { $0.1 }.joined())
            }
        }
        return HeaderValue(value: main, params: params)
    }

    /// charset'lang'percent-encoded
    private static func decodeExtended(_ value: String) -> String {
        let parts = value.components(separatedBy: "'")
        let charset = parts.count >= 3 ? parts[0] : "utf-8"
        let payload = parts.count >= 3 ? parts[2...].joined(separator: "'") : value
        var bytes = Data()
        let utf8 = Array(payload.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "%"), i + 2 < utf8.count,
               let v = UInt8(String(decoding: utf8[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v)
                i += 3
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return Charset.decode(bytes, charset: charset)
    }

    static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var previous: Character?
        for ch in text {
            if ch == "\"", previous != "\\" { inQuotes.toggle() }
            if ch == separator, !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        parts.append(current)
        return parts
    }
}

/// 헤더 + 본문 한 덩어리(메시지 전체 또는 multipart의 한 파트)
public struct MIMEEntity {
    public let headers: MIMEHeaders
    public let body: Data

    public init(_ data: Data) {
        let raw = Data(data)
        let crlf = raw.range(of: Data("\r\n\r\n".utf8))
        let lf = raw.range(of: Data("\n\n".utf8))
        let split: Range<Data.Index>?
        switch (crlf, lf) {
        case let (a?, b?): split = a.lowerBound < b.lowerBound ? a : b
        case let (a?, nil): split = a
        case let (nil, b?): split = b
        default: split = nil
        }
        if let split {
            headers = MIMEHeaders.parse(raw.subdata(in: 0..<split.lowerBound))
            body = raw.subdata(in: split.upperBound..<raw.count)
        } else {
            headers = MIMEHeaders.parse(raw)
            body = Data()
        }
    }

    public var contentType: HeaderValue {
        headers.parameterized("content-type") ?? HeaderValue(value: "text/plain", params: [:])
    }

    /// Content-Transfer-Encoding을 푼 본문
    public var decodedBody: Data {
        switch headers["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable": return TransferCoding.decodeQuotedPrintable(body)
        default: return body
        }
    }

    public var parts: [MIMEEntity] {
        guard contentType.value.hasPrefix("multipart/"), let boundary = contentType.params["boundary"] else { return [] }
        return TransferCoding.splitMultipart(body, boundary: boundary).map(MIMEEntity.init)
    }
}

public enum TransferCoding {
    public static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = Array(data)
        var out = Data(capacity: bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == UInt8(ascii: "=") else {
                out.append(b)
                i += 1
                continue
            }
            if i + 1 < bytes.count, bytes[i + 1] == 0x0A {            // soft break (LF)
                i += 2
            } else if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {  // soft break (CRLF)
                i += 3
            } else if i + 2 < bytes.count,
                      let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    /// multipart 본문을 boundary 기준으로 자른다. 닫는 구분자가 없어도 마지막 파트를 살린다.
    public static func splitMultipart(_ source: Data, boundary: String) -> [Data] {
        let body = Data(source)
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchStart = 0
        var partStart: Int?

        while searchStart < body.count, let found = body.range(of: delimiter, in: searchStart..<body.count) {
            let atLineStart = found.lowerBound == 0 || body[found.lowerBound - 1] == 0x0A
            guard atLineStart else {
                searchStart = found.upperBound
                continue
            }
            if let start = partStart {
                var end = found.lowerBound
                if end > start, body[end - 1] == 0x0A { end -= 1 }
                if end > start, body[end - 1] == 0x0D { end -= 1 }
                parts.append(body.subdata(in: start..<end))
                partStart = nil
            }
            let after = found.upperBound
            if after + 1 < body.count, body[after] == 0x2D, body[after + 1] == 0x2D { return parts }
            guard let newline = body[after...].firstIndex(of: 0x0A) else { return parts }
            partStart = newline + 1
            searchStart = newline + 1
        }
        if let start = partStart, start < body.count {
            parts.append(body.subdata(in: start..<body.count))
        }
        return parts
    }
}
