import AppKit
import MailCore

/// 규칙 하나를 만들거나 고치는 시트
final class RuleSheetController: NSWindowController {
    private enum ActionKind: Int, CaseIterable {
        case move, markRead, flag, trash

        var title: String {
            switch self {
            case .move: return "사서함으로 이동"
            case .markRead: return "읽음으로 표시"
            case .flag: return "깃발 표시"
            case .trash: return "휴지통으로 이동"
            }
        }
    }

    private let manager: AccountManager
    private let original: MailRule?
    private let onSave: (MailRule) -> Void
    private let nameField = NSTextField()
    private let accountPopup = NSPopUpButton()
    private let fieldPopup = NSPopUpButton()
    private let keywordField = NSTextField()
    private let actionPopup = NSPopUpButton()
    private let mailboxPopup = NSPopUpButton()
    private let messageLabel = NSTextField(labelWithString: "")
    private var mailboxes: [Mailbox] = []

    init(manager: AccountManager, rule: MailRule?, onSave: @escaping (MailRule) -> Void) {
        self.manager = manager
        original = rule
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        buildContent(in: window, title: rule == nil ? "새 규칙" : "규칙 수정")
        populate(rule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    private func buildContent(in window: NSWindow, title: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        nameField.placeholderString = "예: 뉴스레터 정리"
        keywordField.placeholderString = "포함할 글자 (예: newsletter)"
        accountPopup.addItems(withTitles: manager.stores.map(\.account.email))
        fieldPopup.addItems(withTitles: RuleText.fields.map(\.1))
        actionPopup.addItems(withTitles: ActionKind.allCases.map(\.title))
        for popup in [accountPopup, actionPopup] {
            popup.target = self
            popup.action = #selector(selectionChanged)
        }

        let grid = NSGridView(views: [
            [caption("이름"), nameField],
            [caption("계정"), accountPopup],
            [caption("조건"), fieldPopup],
            [caption("포함"), keywordField],
            [caption("동작"), actionPopup],
            [caption("사서함"), mailboxPopup],
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .systemRed
        let cancel = NSButton(title: "취소", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "저장", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [messageLabel, NSView(), cancel, save])
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = nameField
        let order: [NSView] = [nameField, keywordField]
        nameField.nextKeyView = keywordField
        keywordField.nextKeyView = order[0]
    }

    private func populate(_ rule: MailRule?) {
        if let rule {
            nameField.stringValue = rule.name
            keywordField.stringValue = rule.keyword
            if let index = manager.stores.firstIndex(where: { $0.account.email.lowercased() == rule.accountEmail.lowercased() }) {
                accountPopup.selectItem(at: index)
            }
            fieldPopup.selectItem(at: RuleText.fields.firstIndex { $0.0 == rule.field } ?? 0)
            switch rule.action {
            case .move: actionPopup.selectItem(at: ActionKind.move.rawValue)
            case .markRead: actionPopup.selectItem(at: ActionKind.markRead.rawValue)
            case .flag: actionPopup.selectItem(at: ActionKind.flag.rawValue)
            case .trash: actionPopup.selectItem(at: ActionKind.trash.rawValue)
            }
        } else if let current = manager.current, let index = manager.stores.firstIndex(where: { $0 === current }) {
            accountPopup.selectItem(at: index)
        }
        reloadMailboxes()
        if case .move(let path)? = rule?.action, let index = mailboxes.firstIndex(where: { $0.path == path }) {
            mailboxPopup.selectItem(at: index)
        }
    }

    /// 고른 계정의 사서함 중 옮길 수 있는 곳만 보여준다.
    private func reloadMailboxes() {
        let store = accountPopup.indexOfSelectedItem >= 0 ? manager.stores[accountPopup.indexOfSelectedItem] : nil
        mailboxes = (store?.mailboxes ?? []).filter { ![.inbox, .flagged, .important, .drafts, .sent].contains($0.role) }
        mailboxPopup.removeAllItems()
        mailboxPopup.addItems(withTitles: mailboxes.map { $0.role == .other ? $0.name : $0.displayName })
        mailboxPopup.isEnabled = actionPopup.indexOfSelectedItem == ActionKind.move.rawValue && !mailboxes.isEmpty
    }

    @objc private func selectionChanged() {
        reloadMailboxes()
    }

    @objc private func cancel() {
        dismiss()
    }

    @objc private func save() {
        let keyword = keywordField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return fail("포함할 글자를 입력하세요.", keywordField) }
        guard accountPopup.indexOfSelectedItem >= 0 else { return fail("계정을 고르세요.", nil) }
        let kind = ActionKind(rawValue: actionPopup.indexOfSelectedItem) ?? .markRead
        let action: MailRule.Action
        switch kind {
        case .move:
            guard mailboxPopup.indexOfSelectedItem >= 0, mailboxPopup.indexOfSelectedItem < mailboxes.count else {
                return fail("옮길 사서함을 고르세요.", nil)
            }
            action = .move(path: mailboxes[mailboxPopup.indexOfSelectedItem].path)
        case .markRead: action = .markRead
        case .flag: action = .flag
        case .trash: action = .trash
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        onSave(MailRule(id: original?.id ?? UUID(), name: name.isEmpty ? "‘\(keyword)’ 규칙" : name,
                        accountEmail: manager.stores[accountPopup.indexOfSelectedItem].account.email,
                        isEnabled: original?.isEnabled ?? true,
                        field: RuleText.fields[max(0, fieldPopup.indexOfSelectedItem)].0, keyword: keyword, action: action))
        dismiss()
    }

    private func fail(_ message: String, _ field: NSView?) {
        messageLabel.stringValue = message
        if let field { window?.makeFirstResponder(field) }
    }

    private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
