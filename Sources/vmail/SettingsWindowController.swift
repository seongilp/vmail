import AppKit
import MailCore

/// 설정 창: 일반 · 계정 탭. 창 크기는 각 탭의 내용에 딱 맞춘다.
final class SettingsWindowController: NSWindowController {
    static let contentWidth: CGFloat = 560
    static let margin: CGFloat = 16
    /// 탭을 바꿔도 창 높이가 흔들리지 않게 모든 탭이 같은 높이를 쓴다.
    static let contentHeight: CGFloat = 248

    private let tabs = NSTabViewController()

    init(manager: AccountManager) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab(GeneralSettingsViewController(), "일반", "gearshape"))
        tabs.addTabViewItem(Self.tab(AccountsSettingsViewController(manager: manager), "계정", "at"))
        window.contentViewController = tabs
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    private static func tab(_ controller: NSViewController, _ title: String, _ symbol: String) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        controller.title = title
        return item
    }

    func show(accounts: Bool) {
        tabs.selectedTabViewItemIndex = accounts ? 1 : 0
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 일반: 알림, 원격 이미지, 서명
final class GeneralSettingsViewController: NSViewController, NSTextViewDelegate {
    private let notifyBox = NSButton(checkboxWithTitle: "새 메일이 오면 알림 표시", target: nil, action: nil)
    private let remoteBox = NSButton(checkboxWithTitle: "원격 이미지 항상 불러오기", target: nil, action: nil)
    private let signatureView = NSTextView()

    override func loadView() {
        notifyBox.state = Preferences.notifyNewMail ? .on : .off
        remoteBox.state = Preferences.alwaysLoadRemoteContent ? .on : .off
        for box in [notifyBox, remoteBox] {
            box.target = self
            box.action = #selector(toggled)
        }
        let remoteNote = NSTextField(labelWithString: "켜면 보낸 사람이 메일을 열어 봤는지 알 수 있습니다.")
        remoteNote.font = .systemFont(ofSize: 11)
        remoteNote.textColor = .secondaryLabelColor

        signatureView.string = Preferences.signature
        signatureView.font = .systemFont(ofSize: 13)
        signatureView.isRichText = false
        signatureView.delegate = self
        signatureView.textContainerInset = NSSize(width: 2, height: 4)
        signatureView.autoresizingMask = [.width]
        signatureView.setAccessibilityLabel("서명")
        let scroll = NSScrollView()
        scroll.documentView = signatureView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        let options = NSStackView(views: [notifyBox, remoteBox, remoteNote])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 6
        options.setCustomSpacing(2, after: remoteBox)
        remoteNote.leadingAnchor.constraint(equalTo: options.leadingAnchor, constant: 20).isActive = true

        // 레이블 열 + 내용 열. 남는 높이는 서명 칸이 모두 가져간다.
        let mailLabel = caption("메일:")
        let signatureLabel = caption("서명:")
        let margin = SettingsWindowController.margin
        let labelWidth: CGFloat = 40
        let container = NSView()
        for sub in [mailLabel, options, signatureLabel, scroll] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth),
            container.heightAnchor.constraint(equalToConstant: SettingsWindowController.contentHeight),
            mailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            mailLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            mailLabel.firstBaselineAnchor.constraint(equalTo: notifyBox.firstBaselineAnchor),
            options.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            options.leadingAnchor.constraint(equalTo: mailLabel.trailingAnchor, constant: 8),
            options.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),
            signatureLabel.leadingAnchor.constraint(equalTo: mailLabel.leadingAnchor),
            signatureLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            signatureLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 3),
            scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: options.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
        ])
        view = container
    }

    @objc private func toggled() {
        Preferences.notifyNewMail = notifyBox.state == .on
        Preferences.alwaysLoadRemoteContent = remoteBox.state == .on
        if Preferences.notifyNewMail { NewMailNotifier.requestAuthorization() }
    }

    func textDidChange(_ notification: Notification) {
        Preferences.signature = signatureView.string
    }
}

/// 계정: 왼쪽 목록(+/−)과 오른쪽 상세 카드
final class AccountsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("account")
    private static let listWidth: CGFloat = 190

    private let manager: AccountManager
    private let tableView = NSTableView()
    private let addRemove = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "plus", accessibilityDescription: "계정 추가") ?? NSImage(),
        NSImage(systemSymbolName: "minus", accessibilityDescription: "계정 제거") ?? NSImage(),
    ], trackingMode: .momentary, target: nil, action: nil)
    private let card = NSBox()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let usernameLabel = NSTextField(labelWithString: "")
    private let imapLabel = NSTextField(labelWithString: "")
    private let smtpLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "수정…", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "계정이 없습니다.\n왼쪽 아래 + 를 눌러 추가하세요.")

    init(manager: AccountManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    private var selectedStore: MailStore? {
        let row = tableView.selectedRow
        return row >= 0 && row < manager.stores.count ? manager.stores[row] : nil
    }

    override func loadView() {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("계정")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addRemove.segmentStyle = .smallSquare
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked)
        addRemove.translatesAutoresizingMaskIntoConstraints = false

        card.boxType = .custom
        card.cornerRadius = 8
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .quaternaryLabelColor.withAlphaComponent(0.06)
        card.titlePosition = .noTitle
        card.contentViewMargins = .zero
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentView = makeCardContent()

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let margin = SettingsWindowController.margin
        let container = NSView()
        for sub in [scroll, addRemove, card, emptyLabel] { container.addSubview(sub) }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth),
            container.heightAnchor.constraint(equalToConstant: SettingsWindowController.contentHeight),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            scroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            // 목록 바로 아래에 +/− 를 붙인다
            scroll.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: 1),
            addRemove.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            addRemove.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
            card.topAnchor.constraint(equalTo: scroll.topAnchor),
            card.bottomAnchor.constraint(equalTo: addRemove.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            emptyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        view = container
    }

    /// 카드: 머리(아이콘·주소·상태) / 구분선 / 항목 표 / 수정 버튼
    private func makeCardContent() -> NSView {
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isSelectable = true
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let status = NSStackView(views: [statusDot, statusLabel])
        status.spacing = 5
        let titles = NSStackView(views: [titleLabel, status])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [iconView, titles])
        header.spacing = 10

        let line = NSBox()
        line.boxType = .separator

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }
        for label in [nameLabel, usernameLabel, imapLabel, smtpLabel] {
            label.font = .systemFont(ofSize: 12)
            label.isSelectable = true
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let grid = NSGridView(views: [
            [caption("이름"), nameLabel],
            [caption("사용자 이름"), usernameLabel],
            [caption("받는 서버"), imapLabel],
            [caption("보내는 서버"), smtpLabel],
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(editAccount)

        let content = NSView()
        for sub in [header, line, grid, editButton] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(sub)
        }
        let inset: CGFloat = 14
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -inset),
            line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            grid.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -inset),
            editButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            editButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        return content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reload), name: AccountManager.accountsDidChange, object: manager)
        center.addObserver(self, selector: #selector(updateDetail), name: MailStore.mailboxesDidChange, object: nil)
        reload()
    }

    @objc private func reload() {
        let previous = selectedStore
        tableView.reloadData()
        let row = manager.stores.firstIndex { $0 === previous } ?? (manager.stores.isEmpty ? -1 : 0)
        if row >= 0 { tableView.selectRowIndexes([row], byExtendingSelection: false) }
        updateDetail()
    }

    @objc private func updateDetail() {
        let store = selectedStore
        card.contentView?.isHidden = store == nil
        emptyLabel.isHidden = store != nil
        addRemove.setEnabled(store != nil, forSegment: 1)
        guard let store else { return }
        let account = store.account
        iconView.image = NSImage(systemSymbolName: account.symbolName, accessibilityDescription: nil)
        titleLabel.stringValue = account.email
        let (color, text): (NSColor, String)
        if let error = store.mailboxError {
            (color, text) = (.systemRed, error)
        } else if store.mailboxes.isEmpty {
            (color, text) = (.systemYellow, "연결하는 중…")
        } else {
            (color, text) = (.systemGreen, "온라인 · IMAP")
        }
        statusDot.layer?.backgroundColor = color.cgColor
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        nameLabel.stringValue = account.displayName.isEmpty ? "—" : account.displayName
        usernameLabel.stringValue = account.username
        imapLabel.stringValue = "\(account.imapHost):\(account.imapPort)"
        smtpLabel.stringValue = "\(account.smtpHost):\(account.smtpPort)"
    }

    // MARK: - 액션

    @objc private func addRemoveClicked() {
        if addRemove.selectedSegment == 0 {
            guard let window = view.window else { return }
            AccountSheetController.present(on: window, manager: manager)
        } else {
            removeAccount()
        }
    }

    @objc private func editAccount() {
        guard let window = view.window, let store = selectedStore else { return }
        AccountSheetController.present(on: window, manager: manager, editing: store)
    }

    private func removeAccount() {
        guard let window = view.window, let store = selectedStore else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(store.account.email) 계정을 제거할까요?"
        alert.informativeText = "이 Mac에 저장된 비밀번호와 캐시가 삭제됩니다. 서버의 메일은 그대로 남습니다."
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.manager.remove(store) }
        }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        manager.stores.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? AccountCellView ?? AccountCellView()
        cell.identifier = Self.cellID
        cell.configure(manager.stores[row].account)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }
}

private extension Account {
    /// 서비스에 맞는 아이콘
    var symbolName: String {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        return ["icloud.com", "me.com", "mac.com"].contains(domain) ? "icloud.fill" : "envelope.fill"
    }
}

private final class AccountCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for sub in [icon, title] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    func configure(_ account: Account) {
        icon.image = NSImage(systemSymbolName: account.symbolName, accessibilityDescription: nil)
        title.stringValue = account.email
        title.toolTip = account.email
    }
}
