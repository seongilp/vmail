import Foundation

/// 메일 서비스가 발급하는 앱 비밀번호 형식 인식
public enum AppPassword {
    // Google: "abcd efgh ijkl mnop" (공백은 표시용) / Apple: "abcd-efgh-ijkl-mnop" (하이픈 포함)
    private static let google = try! NSRegularExpression(pattern: "^[a-z]{4} ?[a-z]{4} ?[a-z]{4} ?[a-z]{4}$")
    private static let apple = try! NSRegularExpression(pattern: "^[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}$")

    /// 앱 비밀번호처럼 보이면 로그인에 쓸 형태로 돌려주고, 아니면 nil.
    public static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if google.firstMatch(in: trimmed, range: range) != nil {
            return trimmed.replacingOccurrences(of: " ", with: "")
        }
        if apple.firstMatch(in: trimmed, range: range) != nil { return trimmed }
        return nil
    }
}
