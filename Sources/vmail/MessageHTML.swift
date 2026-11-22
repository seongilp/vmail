import AppKit
import MailCore

/// 메시지 본문을 WKWebView에 넣을 HTML 문서로 만든다. 글꼴·색·배경은 설정(글꼴 및 색상, 보기)을 따른다.
enum MessageHTML {
    private static let remoteRegex = try! NSRegularExpression(
        pattern: "(src|background)\\s*=\\s*[\"']?https?:|url\\(\\s*[\"']?https?:", options: .caseInsensitive)
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func document(for message: ParsedMessage) -> String {
        let scheme = Preferences.darkMessageBackground ? "light dark" : "light"
        if let html = message.html {
            // HTML 메일은 흰 배경을 전제로 디자인되므로 라이트로 고정한다.
            return wrap(html, colorScheme: "light", font: Preferences.messageFont)
        }
        let text = message.text ?? ""
        let font = Preferences.useFixedFontForPlainText ? Preferences.fixedFont : Preferences.messageFont
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wrap("<p style=\"color:#888\">본문이 없는 메시지입니다.</p>", colorScheme: scheme, font: font)
        }
        return wrap("<div class=\"plain\">\(quotedHTML(text))</div>", colorScheme: scheme, font: font)
    }

    /// 원격 이미지 등 외부 리소스를 참조하는지
    static func hasRemoteContent(_ message: ParsedMessage) -> Bool {
        guard let html = message.html else { return false }
        return remoteRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }

    private static func wrap(_ body: String, colorScheme: String, font: NSFont) -> String {
        let family = font.fontName.hasPrefix(".") ? "-apple-system" : "'\(font.familyName ?? font.fontName)', -apple-system"
        let quoteRules = Preferences.quoteColors.enumerated().map { index, color in
            Preferences.colorQuotedText
                ? "blockquote.q\(index) { border-left-color: \(color); color: \(color); }"
                : "blockquote.q\(index) { border-left-color: #8886; }"
        }.joined(separator: " ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root { color-scheme: \(colorScheme); }
        \(colorScheme == "light" ? "html { background: #fff; color: #000; }" : "")
        body { font: \(Int(font.pointSize))px/1.55 \(family), sans-serif; margin: 16px 20px; word-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        .plain { white-space: pre-wrap; }
        blockquote { margin: 0 0 0 2px; padding-left: 10px; border-left: 2px solid #8884; }
        \(quoteRules)
        a { color: -apple-system-control-accent; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// 평문의 ‘>’ 인용 단계를 중첩 blockquote로 바꾼다 (단계별 색은 3가지를 돌려 쓴다).
    private static func quotedHTML(_ text: String) -> String {
        var out = ""
        var depth = 0
        var pending: [String] = []

        func flush() {
            if !pending.isEmpty { out += linkified(pending.joined(separator: "\n")) }
            pending = []
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let (level, content) = quoteLevel(of: line)
            if level != depth {
                flush()
                while depth < level {
                    out += "<blockquote class=\"q\(depth % 3)\">"
                    depth += 1
                }
                while depth > level {
                    out += "</blockquote>"
                    depth -= 1
                }
            }
            pending.append(content)
        }
        flush()
        out += String(repeating: "</blockquote>", count: depth)
        return out
    }

    /// 줄 앞의 ‘>’ 개수와 나머지 내용
    private static func quoteLevel(of line: String) -> (Int, String) {
        var level = 0
        var rest = Substring(line)
        while rest.first == ">" {
            level += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return (level, String(rest))
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
