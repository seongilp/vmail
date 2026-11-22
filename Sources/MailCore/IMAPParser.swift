import Foundation

/// IMAP 응답의 토큰 트리.
public indirect enum IMAPValue: Equatable {
    case atom(String)
    case string(Data)      // quoted string 또는 literal
    case list([IMAPValue])
    case null

    public var stringValue: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return Charset.decode(d, charset: nil)
        default: return nil
        }
    }

    public var dataValue: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let s): return Data(s.utf8)
        default: return nil
        }
    }

    public var listValue: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }
}

/// 한 개의 논리 응답 줄(리터럴 포함)을 토큰 트리로 파싱한다.
public struct IMAPParser {
    private let bytes: [UInt8]
    private var pos = 0

    public init(_ data: Data) {
        bytes = Array(data)
    }

    public static func parse(_ data: Data) throws -> [IMAPValue] {
        var parser = IMAPParser(data)
        return try parser.parseAll()
    }

    public mutating func parseAll() throws -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            if pos >= bytes.count { return values }
            values.append(try parseValue())
        }
    }

    private mutating func skipSpaces() {
        while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0D || bytes[pos] == 0x0A { pos += 1 }
    }

    private mutating func parseValue() throws -> IMAPValue {
        guard pos < bytes.count else { throw MailError.malformed("응답이 중간에 끝났습니다.") }
        switch bytes[pos] {
        case UInt8(ascii: "("): return try parseList()
        case UInt8(ascii: "\""): return try parseQuoted()
        case UInt8(ascii: "{"): return try parseLiteral()
        case UInt8(ascii: ")"): throw MailError.malformed("괄호가 맞지 않습니다.")
        default: return parseAtom()
        }
    }

    private mutating func parseList() throws -> IMAPValue {
        pos += 1
        var items: [IMAPValue] = []
        while true {
            skipSpaces()
            guard pos < bytes.count else { throw MailError.malformed("리스트가 닫히지 않았습니다.") }
            if bytes[pos] == UInt8(ascii: ")") {
                pos += 1
                return .list(items)
            }
            items.append(try parseValue())
        }
    }

    private mutating func parseQuoted() throws -> IMAPValue {
        pos += 1
        var out = Data()
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: "\\"), pos + 1 < bytes.count {
                out.append(bytes[pos + 1])
                pos += 2
            } else if b == UInt8(ascii: "\"") {
                pos += 1
                return .string(out)
            } else {
                out.append(b)
                pos += 1
            }
        }
        throw MailError.malformed("문자열이 닫히지 않았습니다.")
    }

    private mutating func parseLiteral() throws -> IMAPValue {
        guard let close = bytes[pos...].firstIndex(of: UInt8(ascii: "}")) else {
            throw MailError.malformed("리터럴 길이가 올바르지 않습니다.")
        }
        let digits = String(decoding: bytes[(pos + 1)..<close], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        guard let count = Int(digits), count >= 0 else {
            throw MailError.malformed("리터럴 길이가 올바르지 않습니다.")
        }
        var start = close + 1
        if start < bytes.count, bytes[start] == 0x0D { start += 1 }
        if start < bytes.count, bytes[start] == 0x0A { start += 1 }
        guard start + count <= bytes.count else { throw MailError.malformed("리터럴이 잘렸습니다.") }
        pos = start + count
        return .string(Data(bytes[start..<(start + count)]))
    }

    /// 공백·괄호 전까지 읽는다. BODY[HEADER.FIELDS (A B)] 처럼 대괄호 안의 공백·괄호는 원자에 포함한다.
    private mutating func parseAtom() -> IMAPValue {
        let start = pos
        var depth = 0
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: "[") { depth += 1 }
            if b == UInt8(ascii: "]"), depth > 0 { depth -= 1 }
            if depth == 0, b == 0x20 || b == UInt8(ascii: "(") || b == UInt8(ascii: ")") || b == 0x0D || b == 0x0A {
                break
            }
            pos += 1
        }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        return text.uppercased() == "NIL" ? .null : .atom(text)
    }
}
