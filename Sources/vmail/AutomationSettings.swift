import AppKit
import MailCore

/// 설정 › 부재중: 자동 응답 켜기, 기간, 제목·내용
final class AutoReplySettingsViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private let enableBox = NSButton(checkboxWithTitle: "부재중 자동 응답 보내기", target: nil, action: nil)
    private let periodBox = NSButton(checkboxWithTitle: "기간 지정", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let subjectField = NSTextField()
    private let bodyView = NSTextView()

    override func loadView() {
        let settings = Preferences.autoReply
        enableBox.state = settings.isEnabled ? .on : .off
        periodBox.state = settings.start != nil || settings.end != nil ? .on : .off
        for box in [enableBox, periodBox] {
            box.target = self
            box.action = #selector(changed)
        }
        let week: TimeInterval = 7 * 24 * 60 * 60
        for (picker, date) in [(startPicker, settings.start ?? Date()), (endPicker, settings.end ?? Date().addingTimeInterval(week))] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            picker.dateValue = date
            picker.target = self
            picker.action = #selector(changed)
        }
        subjectField.stringValue = settings.subject
        subjectField.delegate = self
        bodyView.string = settings.body
        bodyView.font = .systemFont(ofSize: 13)
        bodyView.isRichText = false
        bodyView.delegate = self
        bodyView.textContainerInset = NSSize(width: 2, height: 4)
        bodyView.autoresizingMask = [.width]
        bodyView.setAccessibilityLabel("응답 내용")
        let scroll = NSScrollView()
        scroll.documentView = bodyView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let period = NSStackView(views: [periodBox, startPicker, NSTextField(labelWithString: "~"), endPicker])
        period.spacing = 6
        let note = NSTextField(wrappingLabelWithString:
            "vmail이 실행 중일 때 받은편지함에 새로 도착한 메일에만 응답합니다. 같은 사람에게는 4일에 한 번만 보내고, 뉴스레터·자동 발송 메일에는 보내지 않습니다.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let subjectLabel = NSTextField(labelWithString: "제목:")

        let margin = SettingsWindowController.margin
        let container = NSView()
        for sub in [enableBox, period, subjectLabel, subjectField, scroll, note] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth),
            container.heightAnchor.constraint(equalToConstant: SettingsWindowController.contentHeight),
            enableBox.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            enableBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            period.topAnchor.constraint(equalTo: enableBox.bottomAnchor, constant: 8),
            period.leadingAnchor.constraint(equalTo: enableBox.leadingAnchor),
            subjectLabel.leadingAnchor.constraint(equalTo: enableBox.leadingAnchor),
            subjectLabel.firstBaselineAnchor.constraint(equalTo: subjectField.firstBaselineAnchor),
            subjectField.topAnchor.constraint(equalTo: period.bottomAnchor, constant: 10),
            subjectField.leadingAnchor.constraint(equalTo: subjectLabel.trailingAnchor, constant: 6),
            subjectField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            scroll.topAnchor.constraint(equalTo: subjectField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: enableBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),
            note.leadingAnchor.constraint(equalTo: enableBox.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            note.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
        ])
        view = container
        updateEnabled()
    }

    /// 탭을 다시 열 때 가져오기 등으로 바뀐 값을 반영한다.
    override func viewWillAppear() {
        super.viewWillAppear()
        let settings = Preferences.autoReply
        enableBox.state = settings.isEnabled ? .on : .off
        subjectField.stringValue = settings.subject
        if bodyView.string != settings.body { bodyView.string = settings.body }
        updateEnabled()
    }

    private func updateEnabled() {
        let on = enableBox.state == .on
        periodBox.isEnabled = on
        startPicker.isEnabled = on && periodBox.state == .on
        endPicker.isEnabled = on && periodBox.state == .on
    }

    @objc private func changed() {
        // 끝이 시작보다 앞서지 않게 맞춘다.
        if endPicker.dateValue < startPicker.dateValue { endPicker.dateValue = startPicker.dateValue }
        updateEnabled()
        let hasPeriod = periodBox.state == .on
        let wasEnabled = Preferences.autoReply.isEnabled
        Preferences.autoReply = AutoReplySettings(
            isEnabled: enableBox.state == .on, subject: subjectField.stringValue, body: bodyView.string,
            start: hasPeriod ? startPicker.dateValue : nil, end: hasPeriod ? endPicker.dateValue : nil)
        // 새로 켤 때는 지난 기록을 비워 이번 부재 기간에 다시 한 번씩 응답한다.
        if !wasEnabled, enableBox.state == .on { Preferences.autoReplyLog = [:] }
    }

    func controlTextDidChange(_ note: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }
}

/// 설정 › 규칙: 새 메일 자동 분류 규칙 목록
final class RulesSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("rule")

    private let manager: AccountManager
    private let tableView = NSTableView()
    private let controls = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "plus", accessibilityDescription: "규칙 추가") ?? NSImage(),
        NSImage(systemSymbolName: "minus", accessibilityDescription: "규칙 제거") ?? NSImage(),
    ], trackingMode: .momentary, target: nil, action: nil)
    private let editButton = NSButton(title: "수정…", target: nil, action: nil)
    private let applyButton = NSButton(title: "받은편지함에 지금 적용", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "규칙이 없습니다. + 를 눌러 새 메일을 자동으로 분류하는 규칙을 만드세요.")
    private var rules: [MailRule] = []
    private var sheet: RuleSheetController?

    init(manager: AccountManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    override func loadView() {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editRule)
        tableView.setAccessibilityLabel("규칙")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        controls.segmentStyle = .smallSquare
        controls.target = self
        controls.action = #selector(controlClicked)
        for (button, action) in [(editButton, #selector(editRule)), (applyButton, #selector(applyNow))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        let margin = SettingsWindowController.margin
        let container = NSView()
        for sub in [scroll, controls, editButton, applyButton, emptyLabel] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth),
            container.heightAnchor.constraint(equalToConstant: SettingsWindowController.contentHeight),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: 1),
            controls.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
            editButton.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 8),
            editButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            applyButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            applyButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -24),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        rules = Preferences.rules
        tableView.reloadData()
        emptyLabel.isHidden = !rules.isEmpty
        updateButtons()
    }

    private func updateButtons() {
        let hasSelection = tableView.selectedRow >= 0
        controls.setEnabled(!manager.stores.isEmpty, forSegment: 0)
        controls.setEnabled(hasSelection, forSegment: 1)
        editButton.isEnabled = hasSelection
        applyButton.isEnabled = !rules.isEmpty
    }

    private func save(_ next: [MailRule]) {
        Preferences.rules = next
        reload()
    }

    // MARK: - 액션

    @objc private func controlClicked() {
        if controls.selectedSegment == 0 {
            present(editing: nil)
        } else if tableView.selectedRow >= 0 {
            let target = rules[tableView.selectedRow].id
            save(rules.filter { $0.id != target })
        }
    }

    @objc private func editRule() {
        guard tableView.selectedRow >= 0 else { return }
        present(editing: rules[tableView.selectedRow])
    }

    private func present(editing rule: MailRule?) {
        guard let window = view.window, sheet == nil, !manager.stores.isEmpty else { return }
        let controller = RuleSheetController(manager: manager, rule: rule) { [weak self] saved in
            guard let self else { return }
            let exists = self.rules.contains { $0.id == saved.id }
            self.save(exists ? self.rules.map { $0.id == saved.id ? saved : $0 } : self.rules + [saved])
        }
        guard let sheetWindow = controller.window else { return }
        sheet = controller
        window.beginSheet(sheetWindow) { [weak self] _ in self?.sheet = nil }
    }

    /// 각 계정의 받은편지함에 지금 불러와 있는 메일에 규칙을 적용한다.
    @objc private func applyNow() {
        var count = 0
        for store in manager.stores {
            guard let inbox = store.inboxMailbox else { continue }
            let envelopes = store.state(for: inbox).envelopes
            count += envelopes.count - MailAutomation.applyRules(to: envelopes, store: store, mailbox: inbox).count
        }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "규칙을 적용했습니다"
        alert.informativeText = count > 0 ? "받은편지함에서 메일 \(count)통을 옮기거나 삭제했습니다." : "옮기거나 삭제할 메일은 없었습니다. (읽음·깃발 규칙은 바로 반영됩니다.)"
        alert.beginSheetModal(for: window)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        rules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? RuleCellView ?? RuleCellView()
        cell.identifier = Self.cellID
        let rule = rules[row]
        cell.configure(rule, summary: RuleText.summary(rule, mailboxes: manager.stores.first {
            $0.account.email.lowercased() == rule.accountEmail.lowercased()
        }?.mailboxes ?? []))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}

/// 규칙을 사람이 읽을 문장으로
enum RuleText {
    static let fields: [(MailRule.Field, String)] = [(.from, "보낸 사람"), (.to, "받는 사람"), (.subject, "제목"), (.any, "보낸 사람·받는 사람·제목")]

    static func summary(_ rule: MailRule, mailboxes: [Mailbox]) -> String {
        let field = fields.first { $0.0 == rule.field }?.1 ?? ""
        let action: String
        switch rule.action {
        case .move(let path):
            let mailbox = mailboxes.first { $0.path == path }
            let name = mailbox.map { $0.role == .other ? $0.name : $0.displayName } ?? ModifiedUTF7.decode(path)
            action = "‘\(name)’(으)로 이동"
        case .markRead: action = "읽음으로 표시"
        case .flag: action = "깃발 표시"
        case .trash: action = "휴지통으로 이동"
        }
        return "\(rule.accountEmail) · \(field)에 ‘\(rule.keyword)’ 포함 → \(action)"
    }
}

private final class RuleCellView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        textField = title
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    func configure(_ rule: MailRule, summary: String) {
        title.stringValue = rule.name.isEmpty ? "이름 없는 규칙" : rule.name
        subtitle.stringValue = summary
        subtitle.toolTip = summary
    }
}
