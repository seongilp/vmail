import AppKit
import MailCore
import WebKit

/// 선택한 메시지의 헤더와 본문. 본문은 WKWebView로 그리되 스크립트와 원격 콘텐츠는 기본 차단한다.
final class MessageDetailViewController: NSViewController, WKNavigationDelegate {
    private static let blockRulesID = "block-remote"
    private static let blockRulesJSON = """
        [{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}}]
        """

    private let subjectLabel = NSTextField(wrappingLabelWithString: "")
    private let fromLabel = NSTextField(labelWithString: "")
    private let toLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let attachmentButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let remoteButton = NSButton(title: "원격 이미지 불러오기", target: nil, action: nil)
    private let headerStack = NSStackView()
    private let separator = NSBox()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var webView: WKWebView!

    private var blockRules: WKContentRuleList?
    private var rulesReady = false
    private var pendingRender: (() -> Void)?

    /// 지금 화면에 떠 있는 메시지 (답장에 사용)
    private(set) var current: (envelope: Envelope, mailbox: Mailbox, message: ParsedMessage, store: MailStore)?
    private static let zoomStep: CGFloat = 1.1
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0
    private var requestedKey: String?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // 웹뷰 자체 배경을 끄면 평문 메일이 창 배경과 자연스럽게 이어진다 (HTML 메일은 CSS로 흰 바탕을 준다).
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        subjectLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        subjectLabel.isSelectable = true
        subjectLabel.maximumNumberOfLines = 3
        fromLabel.font = .systemFont(ofSize: 13, weight: .medium)
        for label in [fromLabel, toLabel, dateLabel] {
            label.isSelectable = true
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        toLabel.font = .systemFont(ofSize: 12)
        toLabel.textColor = .secondaryLabelColor
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor

        attachmentButton.bezelStyle = .rounded
        attachmentButton.controlSize = .small
        remoteButton.bezelStyle = .rounded
        remoteButton.controlSize = .small
        remoteButton.target = self
        remoteButton.action = #selector(loadRemoteContent)
        let actions = NSStackView(views: [attachmentButton, remoteButton])
        actions.spacing = 8

        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 3
        headerStack.setViews([subjectLabel, fromLabel, toLabel, dateLabel, actions], in: .top)
        headerStack.setCustomSpacing(8, after: subjectLabel)
        headerStack.setCustomSpacing(8, after: dateLabel)
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for sub in [headerStack, separator, webView!, statusLabel, spinner] { container.addSubview(sub) }
        let guide = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            subjectLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            fromLabel.widthAnchor.constraint(lessThanOrEqualTo: headerStack.widthAnchor),
            toLabel.widthAnchor.constraint(lessThanOrEqualTo: headerStack.widthAnchor),
            separator.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showPlaceholder("메일을 선택하세요")
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: Preferences.didChange, object: nil)
        // 원격 콘텐츠 차단 규칙이 준비되기 전에는 본문을 그리지 않는다.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.blockRulesID, encodedContentRuleList: Self.blockRulesJSON
        ) { [weak self] rules, error in
            guard let self else { return }
            if let error { NSLog("vmail: 차단 규칙 컴파일 실패 — \(error.localizedDescription)") }
            self.blockRules = rules
            self.rulesReady = true
            self.pendingRender?()
            self.pendingRender = nil
        }
    }

    // MARK: - 표시

    /// 선택이 바뀔 때 호출된다. 한 통일 때만 본문을 보여준다.
    func show(_ envelopes: [Envelope], in mailbox: Mailbox?, store: MailStore?) {
        guard let store, let mailbox, envelopes.count == 1, let envelope = envelopes.first else {
            requestedKey = nil
            current = nil
            showPlaceholder(envelopes.count > 1 ? "\(envelopes.count)개의 메일을 선택했습니다" : "메일을 선택하세요")
            return
        }
        let key = "\(store.account.email)|\(mailbox.path)#\(envelope.uid)"
        guard key != requestedKey else { return }
        requestedKey = key
        current = nil

        showHeader(envelope)
        setBodyVisible(false)
        statusLabel.stringValue = "본문을 불러오는 중…"
        statusLabel.isHidden = false
        spinner.startAnimation(nil)

        store.loadBody(envelope, in: mailbox) { [weak self, weak store] result in
            guard let self, self.requestedKey == key else { return }   // 그사이 다른 메일을 골랐으면 버린다
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let message):
                guard let store else { return }
                self.current = (envelope, mailbox, message, store)
                self.render(message, allowRemote: Preferences.alwaysLoadRemoteContent)
                self.markReadIfNeeded(envelope, in: mailbox, store: store, key: key)
            case .failure(let error):
                self.statusLabel.stringValue = error.localizedDescription
                self.statusLabel.isHidden = false
            }
        }
    }

    private func showPlaceholder(_ text: String) {
        headerStack.isHidden = true
        separator.isHidden = true
        setBodyVisible(false)
        spinner.stopAnimation(nil)
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    private func showHeader(_ envelope: Envelope) {
        headerStack.isHidden = false
        separator.isHidden = false
        subjectLabel.stringValue = envelope.subject.isEmpty ? "(제목 없음)" : envelope.subject
        fromLabel.stringValue = envelope.from.map(\.fullDisplay).joined(separator: ", ")
        // 스마트 주소: 켜면 받는 사람을 이름만, 끄면 이름과 주소를 함께 보여준다.
        let recipients = (envelope.to + envelope.cc)
            .map { Preferences.smartAddresses ? $0.displayName : $0.fullDisplay }.joined(separator: ", ")
        toLabel.stringValue = recipients.isEmpty ? "" : "받는 사람: \(recipients)"
        toLabel.isHidden = recipients.isEmpty
        dateLabel.stringValue = ListDateFormatter.detailed(envelope.date)
        attachmentButton.isHidden = true
        remoteButton.isHidden = true
    }

    private func setBodyVisible(_ visible: Bool) {
        webView.isHidden = !visible
        if !visible { webView.loadHTMLString("", baseURL: nil) }
    }

    /// 읽음 처리 설정(즉시 / 잠시 후 / 직접)에 따라 읽음으로 표시한다.
    private func markReadIfNeeded(_ envelope: Envelope, in mailbox: Mailbox, store: MailStore, key: String) {
        guard !envelope.isSeen else { return }
        let mark = { store.setFlag("\\Seen", on: true, envelopes: [envelope], in: mailbox) { _ in } }
        switch Preferences.markRead {
        case .immediately:
            mark()
        case .delayed:
            // 그사이 다른 메일로 넘어갔으면 표시하지 않는다.
            DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.markReadDelay) { [weak self] in
                if self?.requestedKey == key { mark() }
            }
        case .manual:
            break
        }
    }

    /// 글꼴·색·배경 설정이 바뀌면 떠 있는 메일을 다시 그린다.
    @objc private func preferencesChanged() {
        guard let current else { return }
        showHeader(current.envelope)
        render(current.message, allowRemote: Preferences.alwaysLoadRemoteContent)
    }

    // MARK: - 프린트 / 확대

    func printMessage() {
        guard current != nil, let window = view.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// factor: 1보다 크면 확대, 작으면 축소, nil이면 실제 크기
    func zoom(_ factor: CGFloat?) {
        let next = factor.map { webView.pageZoom * ($0 > 1 ? Self.zoomStep : 1 / Self.zoomStep) } ?? 1
        webView.pageZoom = min(max(next, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func render(_ message: ParsedMessage, allowRemote: Bool) {
        guard rulesReady else {
            pendingRender = { [weak self] in self?.render(message, allowRemote: allowRemote) }
            return
        }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if !allowRemote, let blockRules { controller.add(blockRules) }

        statusLabel.isHidden = true
        webView.isHidden = false
        webView.loadHTMLString(MessageHTML.document(for: message), baseURL: nil)
        remoteButton.isHidden = allowRemote || !MessageHTML.hasRemoteContent(message)
        configureAttachments(message.attachments)
    }

    @objc private func loadRemoteContent() {
        guard let current else { return }
        render(current.message, allowRemote: true)
    }

    // MARK: - 첨부

    private func configureAttachments(_ attachments: [Attachment]) {
        attachmentButton.isHidden = attachments.isEmpty
        attachmentButton.removeAllItems()
        guard !attachments.isEmpty else { return }
        attachmentButton.addItem(withTitle: "첨부 \(attachments.count)개")
        attachmentButton.item(at: 0)?.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        let formatter = ByteCountFormatter()
        for (index, attachment) in attachments.enumerated() {
            let size = formatter.string(fromByteCount: Int64(attachment.data.count))
            let item = NSMenuItem(title: "\(attachment.filename) (\(size))", action: #selector(openAttachment(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            attachmentButton.menu?.addItem(item)
        }
        attachmentButton.menu?.addItem(.separator())
        let saveAll = NSMenuItem(title: "모두 다운로드 폴더에 저장", action: #selector(saveAllAttachments), keyEquivalent: "")
        saveAll.target = self
        attachmentButton.menu?.addItem(saveAll)
    }

    @objc private func openAttachment(_ sender: NSMenuItem) {
        guard let attachments = current?.message.attachments, sender.tag < attachments.count else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vmail-\(UUID().uuidString)")
        write([attachments[sender.tag]], to: directory) { urls in
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    @objc private func saveAllAttachments() {
        guard let attachments = current?.message.attachments,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        write(attachments, to: downloads) { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// 파일 쓰기는 백그라운드에서. 같은 이름이 있으면 번호를 붙인다.
    private func write(_ attachments: [Attachment], to directory: URL, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var urls: [URL] = []
                for attachment in attachments {
                    let url = Self.availableURL(in: directory, filename: attachment.filename)
                    try attachment.data.write(to: url, options: .atomic)
                    urls.append(url)
                }
                DispatchQueue.main.async { completion(urls) }
            } catch {
                DispatchQueue.main.async { self?.presentFailure("첨부 파일을 저장하지 못했습니다", error) }
            }
        }
    }

    private static func availableURL(in directory: URL, filename: String) -> URL {
        // 경로 구분자를 없애 디렉터리 밖으로 나가지 못하게 한다.
        let safe = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let name = safe.isEmpty || safe.hasPrefix(".") ? "첨부파일" + safe : safe
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private func presentFailure(_ title: String, _ error: Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: - WKNavigationDelegate

    /// 링크 클릭은 기본 브라우저로 넘기고, 뷰 안에서는 이동하지 않는다.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
