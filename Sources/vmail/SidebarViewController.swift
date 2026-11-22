import AppKit
import MailCore

/// 계정을 최상단에 둔 사서함 트리(소스 리스트)
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("mailbox")
    private static let collapsedKey = "SidebarCollapsedNodes"

    private let store: MailStore
    private let outlineView = NSOutlineView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var root: SidebarNode?
    private var isReloading = false
    /// 계정 줄을 골랐는지 — 계정 줄은 받은편지함을 보여주되 강조는 계정 줄에 남긴다.
    private var accountRowSelected = false
    /// 사용자가 접어 둔 줄 — 새로 고쳐도, 다시 실행해도 유지한다.
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: SidebarViewController.collapsedKey) ?? [])

    init(store: MailStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    override func loadView() {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 14
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(toggleClickedRow)
        outlineView.setAccessibilityLabel("사서함")

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reload), name: MailStore.mailboxesDidChange, object: store)
        center.addObserver(self, selector: #selector(syncSelection), name: MailStore.selectionDidChange, object: store)
        center.addObserver(self, selector: #selector(unreadChanged), name: MailStore.unreadDidChange, object: store)
        reload()
    }

    /// 더블클릭: 하위 항목이 있는 줄(계정·폴더)을 접거나 펼친다.
    @objc private func toggleClickedRow() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode,
              !node.children.isEmpty else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.animator().collapseItem(node)
        } else {
            outlineView.animator().expandItem(node)
        }
    }

    // MARK: - 갱신

    @objc private func reload() {
        isReloading = true
        if let account = store.account, !store.mailboxes.isEmpty {
            root = SidebarTree.build(account: account, mailboxes: store.mailboxes)
        } else {
            root = nil
        }
        outlineView.reloadData()
        if let root { expand(root) }
        isReloading = false
        syncSelection()

        if store.account == nil {
            statusLabel.stringValue = "계정이 없습니다"
        } else if store.mailboxes.isEmpty {
            statusLabel.stringValue = store.mailboxError ?? "사서함을 불러오는 중…"
        } else {
            statusLabel.stringValue = ""
        }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
    }

    /// 사용자가 접어 둔 줄만 빼고 펼친다.
    private func expand(_ node: SidebarNode) {
        guard !node.children.isEmpty, !collapsed.contains(node.key) else { return }
        outlineView.expandItem(node)
        node.children.forEach(expand)
    }

    @objc private func syncSelection() {
        isReloading = true
        defer { isReloading = false }
        guard let root, let selected = store.selectedMailbox, let found = find(selected.path, in: root) else {
            outlineView.deselectAll(nil)
            return
        }
        if selected.role != .inbox { accountRowSelected = false }
        let node = accountRowSelected ? root : found
        let row = outlineView.row(forItem: node)   // 접힌 부모 안에 있으면 -1
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    @objc private func unreadChanged() {
        guard let root, let inbox = root.children.first(where: { $0.mailbox?.role == .inbox }) else { return }
        let row = outlineView.row(forItem: inbox)
        if row >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }

    private func find(_ path: String, in node: SidebarNode) -> SidebarNode? {
        if node.mailbox?.path == path { return node }
        for child in node.children {
            if let found = find(path, in: child) { return found }
        }
        return nil
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return root == nil ? 0 : 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return root as Any }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? MailboxCellView ?? MailboxCellView()
        cell.identifier = Self.cellID
        let badge = node.mailbox?.role == .inbox && store.inboxUnread > 0 ? "\(store.inboxUnread)" : ""
        cell.configure(node, badge: badge)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.mailbox != nil || node.isAccount
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode else { return }
        accountRowSelected = node.isAccount
        // 계정 줄은 그 계정의 받은편지함을 연다.
        let target = node.isAccount ? store.mailboxes.first { $0.role == .inbox } : node.mailbox
        if let target { store.select(target) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        rememberCollapsed(notification, isCollapsed: true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        rememberCollapsed(notification, isCollapsed: false)
        syncSelection()   // 펼친 줄 안에 선택된 사서함이 있으면 다시 강조한다
    }

    private func rememberCollapsed(_ notification: Notification, isCollapsed: Bool) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        collapsed = isCollapsed ? collapsed.union([node.key]) : collapsed.subtracting([node.key])
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }
}

private final class MailboxCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        for sub in [icon, label, badgeLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -6),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    func configure(_ node: SidebarNode, badge: String) {
        icon.image = NSImage(systemSymbolName: node.symbolName, accessibilityDescription: nil)
        label.stringValue = node.title
        label.font = .systemFont(ofSize: 13, weight: node.isAccount ? .semibold : .regular)
        label.textColor = node.mailbox == nil && !node.isAccount ? .secondaryLabelColor : .labelColor
        badgeLabel.stringValue = badge
        setAccessibilityLabel(badge.isEmpty ? node.title : "\(node.title), 읽지 않은 메일 \(badge)개")
    }
}
