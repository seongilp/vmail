import AppKit
import MailCore
import UniformTypeIdentifiers

/// 새 메일 / 답장 / 전달 작성 창
final class ComposeWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private static let maxAttachmentBytes = 25 * 1024 * 1024
    private static let maxCompletions = 8

    var onClose: (() -> Void)?
    private let store: MailStore
    private let draft: ComposeDraft
    private let toField = NSTextField()
    private let ccField = NSTextField()
    private let bccField = NSTextField()
    private let subjectField = NSTextField()
    private let textView = NSTextView()
    private let attachmentButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let attachButton = NSButton(title: "파일 첨부…", target: nil, action: nil)
    private let sendButton = NSButton(title: "보내기", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var attachments: [Attachment]
    private var isBusy = false
    private var isFinished = false          // 보냈거나 저장·버리기로 끝난 상태
    private var isCompleting = false
    private var lastLengths: [ObjectIdentifier: Int] = [:]

    init(store: MailStore, draft: ComposeDraft) {
        self.store = store
        self.draft = draft
        attachments = draft.attachments
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = draft.subject.isEmpty ? "새로운 메일" : draft.subject
        window.minSize = NSSize(width: 460, height: 340)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        updateAttachmentButton()
        window.center()
        window.makeFirstResponder(draft.to.isEmpty ? toField : textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    private func buildContent(in window: NSWindow) {
        toField.stringValue = draft.to
        ccField.stringValue = draft.cc
        bccField.stringValue = draft.bcc
        subjectField.stringValue = draft.subject
        toField.placeholderString = "name@example.com, …"
        let fields = [toField, ccField, bccField, subjectField]
        for field in fields {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            field.delegate = self
        }

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }
        let fromLabel = NSTextField(labelWithString: draft.from.fullDisplay)
        fromLabel.lineBreakMode = .byTruncatingTail
        let grid = NSGridView(views: [
            [label("보내는 사람"), fromLabel],
            [label("받는 사람"), toField],
            [label("참조"), ccField],
            [label("숨은 참조"), bccField],
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

        func line() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            box.translatesAutoresizingMaskIntoConstraints = false
            return box
        }
        let topLine = line()
        let bottomLine = line()

        attachButton.bezelStyle = .rounded
        attachButton.target = self
        attachButton.action = #selector(attachFiles(_:))
        attachmentButton.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.target = self
        sendButton.action = #selector(sendMessage(_:))
        let bar = NSStackView(views: [attachButton, attachmentButton, NSView(), spinner, sendButton])
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
        // Tab 순서: 주소 칸들 → 제목 → 본문
        for (index, field) in fields.enumerated() {
            field.nextKeyView = index + 1 < fields.count ? fields[index + 1] : textView
        }
    }

    // MARK: - 주소 자동 완성

    /// 글자를 입력할 때(지울 때는 제외) 아는 주소 목록을 띄운다.
    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField, field !== subjectField,
              let editor = note.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        let id = ObjectIdentifier(field)
        let length = field.stringValue.count
        defer { lastLengths[id] = length }
        guard !isCompleting, length > lastLengths[id] ?? 0 else { return }
        isCompleting = true
        editor.complete(nil)
        isCompleting = false
    }

    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard control !== subjectField else { return [] }
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        guard partial.count >= 2 else { return [] }
        index.pointee = -1   // 사용자가 고르기 전에는 아무것도 끼워 넣지 않는다
        let matches = store.knownAddresses.filter {
            $0.email.lowercased().hasPrefix(partial) || ($0.name?.lowercased().contains(partial) ?? false)
        }
        return Array(matches.prefix(Self.maxCompletions).map(\.email))
    }

    // MARK: - 첨부

    @objc func attachFiles(_ sender: Any?) {
        guard let window, !isBusy else { return }
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
                    self.updateAttachmentButton()
                }
            } catch {
                DispatchQueue.main.async { self?.present("파일을 첨부하지 못했습니다", error.localizedDescription) }
            }
        }
    }

    /// 첨부 목록 메뉴 — 항목을 고르면 그 첨부를 뺀다.
    private func updateAttachmentButton() {
        attachmentButton.isHidden = attachments.isEmpty
        attachmentButton.removeAllItems()
        guard !attachments.isEmpty else { return }
        attachmentButton.addItem(withTitle: "첨부 \(attachments.count)개")
        let formatter = ByteCountFormatter()
        for (index, attachment) in attachments.enumerated() {
            let size = formatter.string(fromByteCount: Int64(attachment.data.count))
            let item = NSMenuItem(title: "\(attachment.filename) (\(size)) 제거", action: #selector(removeAttachment(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            attachmentButton.menu?.addItem(item)
        }
    }

    @objc private func removeAttachment(_ sender: NSMenuItem) {
        attachments = attachments.enumerated().filter { $0.offset != sender.tag }.map(\.element)
        updateAttachmentButton()
    }

    // MARK: - 보내기 / 임시 저장

    /// 입력을 검증해 보낼 메시지를 만든다. requireRecipient가 false면(임시 저장) 받는 사람이 비어도 된다.
    private func buildMessage(requireRecipient: Bool) -> OutgoingMessage? {
        func addresses(_ field: NSTextField, _ label: String) -> [Address]? {
            if let list = MessageBuilder.parseAddressList(field.stringValue) { return list }
            present("\(label) 주소를 확인하세요", "이메일 주소를 쉼표로 구분해 입력합니다. 예: name@example.com")
            window?.makeFirstResponder(field)
            return nil
        }
        guard let to = addresses(toField, "받는 사람"), let cc = addresses(ccField, "참조"),
              let bcc = addresses(bccField, "숨은 참조") else { return nil }
        if requireRecipient, to.isEmpty, cc.isEmpty, bcc.isEmpty {
            present("받는 사람을 입력하세요", "이메일 주소를 쉼표로 구분해 입력합니다.")
            window?.makeFirstResponder(toField)
            return nil
        }
        return OutgoingMessage(from: draft.from, to: to, cc: cc, bcc: bcc, subject: subjectField.stringValue,
                               body: textView.string, attachments: attachments, inReplyTo: draft.inReplyTo)
    }

    @objc func sendMessage(_ sender: Any?) {
        guard !isBusy, let message = buildMessage(requireRecipient: true) else { return }
        setBusy(true, title: "보내는 중…")
        store.send(message) { [weak self] error in
            guard let self else { return }
            self.setBusy(false, title: "보내기")
            if let error {
                self.present("메일을 보내지 못했습니다", error.localizedDescription)
            } else {
                self.finish()
            }
        }
    }

    @objc func saveDraft(_ sender: Any?) {
        saveDraft(thenClose: false)
    }

    private func saveDraft(thenClose: Bool) {
        guard !isBusy, let message = buildMessage(requireRecipient: false) else { return }
        setBusy(true, title: "저장 중…")
        store.saveDraft(message) { [weak self] error in
            guard let self else { return }
            self.setBusy(false, title: "보내기")
            if let error {
                self.present("임시 저장하지 못했습니다", error.localizedDescription)
            } else if thenClose {
                self.finish()
            } else {
                self.window?.subtitle = "임시보관함에 저장됨"
            }
        }
    }

    /// 보내거나 저장한 뒤: 이어 쓰던 원본 임시 저장본을 지우고 창을 닫는다.
    private func finish() {
        if let source = draft.sourceDraft {
            store.expunge(uids: [source.uid], in: source.mailbox) { error in
                NSLog("vmail: 이전 임시 저장본 삭제 실패 — \(error.localizedDescription)")
            }
        }
        isFinished = true
        close()
    }

    private func setBusy(_ busy: Bool, title: String) {
        isBusy = busy
        for control in [toField, ccField, bccField, subjectField, attachButton, attachmentButton, sendButton] as [NSControl] {
            control.isEnabled = !busy
        }
        textView.isEditable = !busy
        sendButton.title = title
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
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

    private var hasUnsavedChanges: Bool {
        textView.string != draft.body || toField.stringValue != draft.to || ccField.stringValue != draft.cc
            || bccField.stringValue != draft.bcc || subjectField.stringValue != draft.subject
            || attachments != draft.attachments
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isBusy { return false }
        guard !isFinished, hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "작성 중인 메일을 저장할까요?"
        alert.informativeText = "저장하면 임시보관함에서 이어 쓸 수 있습니다."
        alert.addButton(withTitle: "임시 저장")
        alert.addButton(withTitle: "버리기")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveDraft(thenClose: true)
            case .alertSecondButtonReturn:
                self.isFinished = true
                self.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
