import AppKit
import MailCore
import UniformTypeIdentifiers

/// 새 메일 / 답장 작성 창
final class ComposeWindowController: NSWindowController, NSWindowDelegate {
    private static let maxAttachmentBytes = 25 * 1024 * 1024

    var onClose: (() -> Void)?
    private let store: MailStore
    private let draft: ComposeDraft
    private let toField = NSTextField()
    private let ccField = NSTextField()
    private let subjectField = NSTextField()
    private let textView = NSTextView()
    private let attachmentLabel = NSTextField(labelWithString: "")
    private let attachButton = NSButton(title: "파일 첨부…", target: nil, action: nil)
    private let sendButton = NSButton(title: "보내기", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var attachments: [Attachment] = []
    private var isSending = false
    private var didSend = false

    init(store: MailStore, draft: ComposeDraft) {
        self.store = store
        self.draft = draft
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = draft.subject.isEmpty ? "새로운 메일" : draft.subject
        window.minSize = NSSize(width: 440, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
        window.makeFirstResponder(draft.to.isEmpty ? toField : textView)
        if !draft.to.isEmpty { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    private func buildContent(in window: NSWindow) {
        toField.stringValue = draft.to
        ccField.stringValue = draft.cc
        subjectField.stringValue = draft.subject
        toField.placeholderString = "name@example.com, …"
        for field in [toField, ccField, subjectField] {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
        }

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }
        let grid = NSGridView(views: [
            [label("받는 사람"), toField],
            [label("참조"), ccField],
            [label("제목"), subjectField],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        textView.string = draft.body
        textView.font = .systemFont(ofSize: 14)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.setAccessibilityLabel("본문")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let topLine = NSBox()
        topLine.boxType = .separator
        topLine.translatesAutoresizingMaskIntoConstraints = false
        let bottomLine = NSBox()
        bottomLine.boxType = .separator
        bottomLine.translatesAutoresizingMaskIntoConstraints = false

        attachButton.bezelStyle = .rounded
        attachButton.target = self
        attachButton.action = #selector(attachFiles(_:))
        attachmentLabel.textColor = .secondaryLabelColor
        attachmentLabel.lineBreakMode = .byTruncatingMiddle
        attachmentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.target = self
        sendButton.action = #selector(sendMessage(_:))
        let bar = NSStackView(views: [attachButton, attachmentLabel, NSView(), spinner, sendButton])
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for sub in [grid, topLine, scroll, bottomLine, bar] { content.addSubview(sub) }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            topLine.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: bottomLine.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
    }

    // MARK: - 첨부

    @objc func attachFiles(_ sender: Any?) {
        guard let window, !isSending else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addAttachments(panel.urls)
        }
    }

    /// 파일 읽기는 백그라운드에서 한다.
    private func addAttachments(_ urls: [URL]) {
        let existingBytes = attachments.reduce(0) { $0 + $1.data.count }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var loaded: [Attachment] = []
                var total = existingBytes
                for url in urls {
                    let data = try Data(contentsOf: url)
                    total += data.count
                    guard total <= Self.maxAttachmentBytes else {
                        throw MailError.server("첨부 파일은 합쳐서 25MB까지 보낼 수 있습니다.")
                    }
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    loaded.append(Attachment(filename: url.lastPathComponent, mimeType: mime, data: data))
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.attachments = self.attachments + loaded
                    self.updateAttachmentLabel()
                }
            } catch {
                DispatchQueue.main.async { self?.present("파일을 첨부하지 못했습니다", error.localizedDescription) }
            }
        }
    }

    private func updateAttachmentLabel() {
        attachmentLabel.stringValue = attachments.isEmpty ? "" : attachments.map(\.filename).joined(separator: ", ")
        attachmentLabel.toolTip = attachmentLabel.stringValue
    }

    // MARK: - 보내기

    @objc func sendMessage(_ sender: Any?) {
        guard !isSending else { return }
        guard let to = MessageBuilder.parseAddressList(toField.stringValue), !to.isEmpty else {
            return present("받는 사람을 확인하세요", "이메일 주소를 쉼표로 구분해 입력합니다. 예: name@example.com")
        }
        guard let cc = MessageBuilder.parseAddressList(ccField.stringValue) else {
            return present("참조 주소를 확인하세요", "이메일 주소를 쉼표로 구분해 입력합니다.")
        }
        let message = OutgoingMessage(from: draft.from, to: to, cc: cc, subject: subjectField.stringValue,
                                      body: textView.string, attachments: attachments, inReplyTo: draft.inReplyTo)
        setSending(true)
        store.send(message) { [weak self] error in
            guard let self else { return }
            self.setSending(false)
            if let error {
                self.present("메일을 보내지 못했습니다", error.localizedDescription)
            } else {
                self.didSend = true
                self.close()
            }
        }
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        for control in [toField, ccField, subjectField, attachButton, sendButton] as [NSControl] {
            control.isEnabled = !sending
        }
        textView.isEditable = !sending
        sendButton.title = sending ? "보내는 중…" : "보내기"
        if sending { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func present(_ title: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    // MARK: - NSWindowDelegate

    private var hasUnsentChanges: Bool {
        !didSend && (textView.string != draft.body || toField.stringValue != draft.to
            || subjectField.stringValue != draft.subject || !attachments.isEmpty)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isSending { return false }
        guard hasUnsentChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "작성 중인 메일을 버릴까요?"
        alert.informativeText = "이 메일은 저장되지 않습니다."
        alert.addButton(withTitle: "버리기")
        alert.addButton(withTitle: "계속 작성")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.didSend = true
            self?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
