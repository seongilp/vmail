import Foundation

/// 메일에 쓰이는 IANA charset 이름을 문자열로 디코딩한다.
public enum Charset {
    /// CP949 — EUC-KR의 상위 집합이라 한국어 레거시 메일을 모두 덮는다.
    static let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    private static let koreanAliases: Set<String> = [
        "euc-kr", "ks_c_5601-1987", "ks_c_5601", "ksc5601", "cp949", "ms949", "x-windows-949", "windows-949", "korean",
    ]

    public static func encoding(named name: String) -> String.Encoding? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return nil }
        if key == "utf-8" || key == "utf8" { return .utf8 }
        if koreanAliases.contains(key) { return korean }
        let cf = CFStringConvertIANACharSetNameToEncoding(key as CFString)
        if cf == kCFStringEncodingInvalidId { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// 선언된 charset으로 디코딩하고, 실패하면 UTF-8 → CP949 → 손실 UTF-8 순으로 폴백한다.
    public static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let enc = encoding(named: charset), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: korean) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
