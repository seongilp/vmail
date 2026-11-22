import Foundation

/// RFC 2047 encoded-word (=?charset?B|Q?...?=) 디코딩/인코딩.
public enum HeaderCoding {
    private static let wordRegex = try! NSRegularExpression(
        pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?=")
    private static let maxChunkBytes = 45  // base64 60자 → encoded-word 75자 이내

    public static func decode(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        let ns = raw as NSString
        let matches = wordRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return raw }

        var result = ""
        var last = 0
        // 같은 charset의 연속 단어는 바이트를 이어 붙여 한 번에 디코딩한다(멀티바이트 문자가 단어 경계에서 쪼개질 수 있음).
        var pending: (charset: String, data: Data)?

        func flush() {
            if let p = pending { result += Charset.decode(p.data, charset: p.charset) }
            pending = nil
        }

        for m in matches {
            let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // "\r\n"은 Character 하나로 묶이므로 스칼라 단위로 본다.
            let onlySpace = between.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            if !(onlySpace && pending != nil) {
                flush()
                result += between
            }
            let charset = ns.substring(with: m.range(at: 1)).components(separatedBy: "*")[0].lowercased()
            let kind = ns.substring(with: m.range(at: 2)).lowercased()
            let payload = ns.substring(with: m.range(at: 3))
            let bytes = kind == "b"
                ? (Data(base64Encoded: padded(payload), options: .ignoreUnknownCharacters) ?? Data())
                : decodeQ(payload)
            if let p = pending, p.charset == charset {
                pending = (charset, p.data + bytes)
            } else {
                flush()
                pending = (charset, bytes)
            }
            last = m.range.location + m.range.length
        }
        flush()
        result += ns.substring(from: last)
        return result
    }

    /// ASCII가 아니면 UTF-8 base64 encoded-word로 감싼다. 긴 값은 여러 단어로 접는다.
    public static func encode(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 && $0 >= 0x20 }) { return text }
        var words: [String] = []
        var chunk = Data()
        for ch in text {
            let bytes = Data(String(ch).utf8)
            if chunk.count + bytes.count > maxChunkBytes, !chunk.isEmpty {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    static func padded(_ base64: String) -> String {
        let rem = base64.count % 4
        return rem == 0 ? base64 : base64 + String(repeating: "=", count: 4 - rem)
    }

    private static func decodeQ(_ text: String) -> Data {
        var out = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "_") {
                out.append(0x20)
            } else if b == UInt8(ascii: "="), i + 2 < bytes.count,
                      let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 2
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }
}

/// IMAP 사서함 이름의 modified UTF-7 (RFC 3501 5.1.3) 디코딩.
public enum ModifiedUTF7 {
    /// 사서함 이름을 서버에 보낼 modified UTF-7로 인코딩한다.
    public static func encode(_ text: String) -> String {
        var result = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var data = Data(capacity: pending.count * 2)
            for unit in pending {
                data.append(UInt8(unit >> 8))
                data.append(UInt8(unit & 0xFF))
            }
            let b64 = data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: ",")
            result += "&" + b64 + "-"
            pending = []
        }

        for unit in text.utf16 {
            if unit == 0x26 {                     // "&"
                flush()
                result += "&-"
            } else if unit >= 0x20 && unit <= 0x7E {
                flush()
                result.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                pending.append(unit)
            }
        }
        flush()
        return result
    }

    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let dash = after.firstIndex(of: "-") else {
                result += rest[amp...]
                return result
            }
            let encoded = after[..<dash]
            if encoded.isEmpty {
                result += "&"
            } else {
                let b64 = HeaderCoding.padded(encoded.replacingOccurrences(of: ",", with: "/"))
                if let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf16BigEndian) {
                    result += s
                } else {
                    result += "&" + encoded + "-"
                }
            }
            rest = after[after.index(after: dash)...]
        }
        result += rest
        return result
    }
}
