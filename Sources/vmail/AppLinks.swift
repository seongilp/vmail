import AppKit

/// 앱 밖으로 나가는 링크 (후원, 저장소)
enum AppLinks {
    static let sponsor = URL(string: "https://ko-fi.com/seongilp")
    static let repository = URL(string: "https://github.com/seongilp/vmail")

    static func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }

    /// ‘vmail에 관하여’ 창: 기본 정보 아래에 후원·GitHub 링크를 넣는다.
    static func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: "가볍고 빠른 macOS 네이티브 메일 앱\n\n", attributes: base)
        for (index, link) in [("후원하기", sponsor), ("GitHub", repository)].enumerated() {
            if index > 0 { credits.append(NSAttributedString(string: "   ·   ", attributes: base)) }
            var attributes = base
            if let url = link.1 { attributes[.link] = url }
            credits.append(NSAttributedString(string: link.0, attributes: attributes))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
