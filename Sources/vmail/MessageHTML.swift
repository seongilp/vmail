import Foundation
import MailCore

/// 메시지 본문을 WKWebView에 넣을 HTML 문서로 만든다.
enum MessageHTML {
    private static let remoteRegex = try! NSRegularExpression(
        pattern: "(src|background)\\s*=\\s*[\"']?https?:|url\\(\\s*[\"']?https?:", options: .caseInsensitive)
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let baseStyle = """
        body { font: 14px/1.55 -apple-system, sans-serif; margin: 16px 20px; word-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        pre { white-space: pre-wrap; font: inherit; margin: 0; }
        blockquote { margin: 0 0 0 8px; padding-left: 10px; border-left: 2px solid #8884; }
        a { color: -apple-system-control-accent; }
        """

    static func document(for message: ParsedMessage) -> String {
        if let html = message.html {
            // HTML 메일은 흰 배경을 전제로 디자인되므로 라이트로 고정한다.
            return wrap(html, colorScheme: "light")
        }
        let text = message.text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wrap("<p style=\"color:#888\">본문이 없는 메시지입니다.</p>", colorScheme: "light dark")
        }
        return wrap("<pre>\(linkified(text))</pre>", colorScheme: "light dark")
    }

    /// 원격 이미지 등 외부 리소스를 참조하는지
    static func hasRemoteContent(_ message: ParsedMessage) -> Bool {
        guard let html = message.html else { return false }
        return remoteRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }

    private static func wrap(_ body: String, colorScheme: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root { color-scheme: \(colorScheme); } \(baseStyle)</style></head>
        <body>\(body)</body></html>
        """
    }

    /// 평문을 이스케이프하면서 URL만 링크로 바꾼다.
    private static func linkified(_ text: String) -> String {
        guard let detector = linkDetector else { return HTMLText.escape(text) }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { continue }
            out += HTMLText.escape(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            let label = HTMLText.escape(ns.substring(with: match.range))
            out += "<a href=\"\(HTMLText.escape(url.absoluteString))\">\(label)</a>"
            last = match.range.location + match.range.length
        }
        out += HTMLText.escape(ns.substring(from: last))
        return out
    }
}
