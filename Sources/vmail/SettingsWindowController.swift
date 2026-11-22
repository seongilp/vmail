import AppKit
import MailCore

/// 설정 창: 일반 · 계정 탭
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(manager: AccountManager) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
    private let remoteBox = NSButton(checkboxWithTitle: "원격 이미지를 항상 불러오기 (보낸 사람이 열람 여부를 알 수 있음)", target: nil, action: nil)
    private let signatureView = NSTextView()

    override func loadView() {
        notifyBox.state = Preferences.notifyNewMail ? .on : .off
        remoteBox.state = Preferences.alwaysLoadRemoteContent ? .on : .off
        for box in [notifyBox, remoteBox] {
            box.target = self
            box.action = #selector(toggled)
        }

        signatureView.string = Preferences.signature
        signatureView.font = .systemFont(ofSize: 13)
        signatureView.isRichText = false
        signatureView.delegate = self
        signatureView.textContainerInset = NSSize(width: 4, height: 6)
        signatureView.autoresizingMask = [.width]
        signatureView.setAccessibilityLabel("서명")
        let scroll = NSScrollView()
        scroll.documentView = signatureView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let signatureLabel = NSTextField(labelWithString: "서명 — 새 메일과 답장 끝에 붙습니다")
        signatureLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [notifyBox, remoteBox, signatureLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: remoteBox)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: 640),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            scroll.heightAnchor.constraint(equalToConstant: 150),
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

/// 계정: 왼쪽 목록(+/−)과 오른쪽 상세
final class AccountsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("account")

    private let manager: AccountManager
    private let tableView = NSTableView()
    private let addRemove = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "plus", accessibilityDescription: "계정 추가") ?? NSImage(),
        NSImage(systemSymbolName: "minus", accessibilityDescription: "계정 제거") ?? NSImage(),
    ], trackingMode: .momentary, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let emailLabel = NSTextField(labelWithString: "")
    private let imapLabel = NSTextField(labelWithString: "")
    private let smtpLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "수정…", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "계정이 없습니다.\n왼쪽 아래 + 를 눌러 추가하세요.")
    private var detailGrid = NSGridView()

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
        tableView.rowHeight = 44
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("계정")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked)
        addRemove.translatesAutoresizingMaskIntoConstraints = false

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }
        for label in [nameLabel, emailLabel, imapLabel, smtpLabel, statusLabel] {
            label.isSelectable = true
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editAccount)
        detailGrid = NSGridView(views: [
            [caption("상태"), statusLabel],
            [caption("이름"), nameLabel],
            [caption("이메일"), emailLabel],
            [caption("받는 서버"), imapLabel],
            [caption("보내는 서버"), smtpLabel],
            [NSGridCell.emptyContentView, editButton],
        ])
        detailGrid.rowSpacing = 10
        detailGrid.columnSpacing = 10
        detailGrid.column(at: 0).xPlacement = .trailing
        detailGrid.rowAlignment = .firstBaseline
        detailGrid.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for sub in [scroll, addRemove, detailGrid, emptyLabel] { container.addSubview(sub) }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 640),
            container.heightAnchor.constraint(equalToConstant: 320),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.widthAnchor.constraint(equalToConstant: 210),
            scroll.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: -8),
            addRemove.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            addRemove.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            detailGrid.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            detailGrid.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            detailGrid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        view = container
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
        let row = manager.stores.firstIndex { $0 === previous } ?? (manager.stores.isEmpty ? -1 : manager.stores.count - 1)
        if row >= 0 { tableView.selectRowIndexes([row], byExtendingSelection: false) }
        updateDetail()
    }

    @objc private func updateDetail() {
        let store = selectedStore
        detailGrid.isHidden = store == nil
        emptyLabel.isHidden = store != nil
        addRemove.setEnabled(store != nil, forSegment: 1)
        guard let store else { return }
        let account = store.account
        if let error = store.mailboxError {
            statusLabel.stringValue = "🔴 \(error)"
        } else {
            statusLabel.stringValue = store.mailboxes.isEmpty ? "🟡 연결하는 중…" : "🟢 온라인"
        }
        nameLabel.stringValue = account.displayName.isEmpty ? "(없음)" : account.displayName
        emailLabel.stringValue = account.email
        imapLabel.stringValue = "\(account.imapHost) : \(account.imapPort)"
        smtpLabel.stringValue = "\(account.smtpHost) : \(account.smtpPort)"
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

private final class AccountCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "IMAP")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for sub in [icon, title, subtitle] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    func configure(_ account: Account) {
        let domain = account.email.components(separatedBy: "@").last?.lowercased() ?? ""
        let isCloud = ["icloud.com", "me.com", "mac.com"].contains(domain)
        icon.image = NSImage(systemSymbolName: isCloud ? "icloud.fill" : "envelope.fill", accessibilityDescription: nil)
        title.stringValue = account.email
    }
}
