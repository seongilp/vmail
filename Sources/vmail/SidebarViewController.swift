import AppKit
import MailCore

/// 계정들을 최상단에 둔 사서함 트리(소스 리스트)
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    /// 메시지 목록에서 끌어 온 메일의 UID
    static let messageDragType = NSPasteboard.PasteboardType("com.zihado.vmail.message-uid")
    private static let cellID = NSUserInterfaceItemIdentifier("mailbox")
    private static let collapsedKey = "SidebarCollapsedNodes"

    let manager: AccountManager
    let outlineView = NSOutlineView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var roots: [SidebarNode] = []
    private var isReloading = false
    /// 계정 줄을 골랐는지 — 계정 줄은 받은편지함을 보여주되 강조는 계정 줄에 남긴다.
    private weak var accountRowStore: MailStore?
    /// 사용자가 접어 둔 줄 — 새로 고쳐도, 다시 실행해도 유지한다.
    private var collapsed = Set(UserDefaults.standard.stringArray(forKey: SidebarViewController.collapsedKey) ?? [])

    init(manager: AccountManager) {
        self.manager = manager
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
        outlineView.registerForDraggedTypes([Self.messageDragType])
        outlineView.setAccessibilityLabel("사서함")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

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
        center.addObserver(self, selector: #selector(reload), name: AccountManager.accountsDidChange, object: manager)
        center.addObserver(self, selector: #selector(reload), name: MailStore.mailboxesDidChange, object: nil)
        center.addObserver(self, selector: #selector(syncSelection), name: AccountManager.currentDidChange, object: manager)
        center.addObserver(self, selector: #selector(syncSelection), name: MailStore.selectionDidChange, object: nil)
        center.addObserver(self, selector: #selector(unreadChanged), name: MailStore.unreadDidChange, object: nil)
        reload()
    }

    // MARK: - 갱신

    @objc private func reload() {
        isReloading = true
        roots = manager.stores.map(SidebarTree.build)
        outlineView.reloadData()
        roots.forEach(expand)
        isReloading = false
        syncSelection()
        statusLabel.stringValue = roots.isEmpty ? "계정이 없습니다" : ""
        statusLabel.isHidden = !roots.isEmpty
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
        guard let store = manager.current, let root = roots.first(where: { $0.store === store }) else {
            outlineView.deselectAll(nil)
            return
        }
        if store.selectedMailbox?.role != .inbox || accountRowStore !== store { accountRowStore = nil }
        let found = store.selectedMailbox.flatMap { find($0.path, in: root) }
        let node = accountRowStore === store ? root : found
        let row = node.map { outlineView.row(forItem: $0) } ?? -1   // 접힌 부모 안에 있으면 -1
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    @objc private func unreadChanged(_ note: Notification) {
        guard let store = note.object as? MailStore, let root = roots.first(where: { $0.store === store }),
              let inbox = root.children.first(where: { $0.mailbox?.role == .inbox }) else { return }
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

    /// 더블클릭: 하위 항목이 있는 줄(계정·폴더)을 접거나 펼친다.
    @objc private func toggleClickedRow() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        toggle(node)
    }

    func toggle(_ node: SidebarNode) {
        guard !node.children.isEmpty else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.animator().collapseItem(node)
        } else {
            outlineView.animator().expandItem(node)
        }
    }

    func presentFailure(_ title: String, _ error: Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    /// 끌어 온 메일은 같은 계정의 다른 사서함 위에만 놓을 수 있다.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? SidebarNode, let mailbox = node.mailbox, index == NSOutlineViewDropOnItemIndex,
              node.store === manager.current, mailbox != node.store.selectedMailbox else { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? SidebarNode, let destination = node.mailbox,
              let source = node.store.selectedMailbox else { return false }
        let uids = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: Self.messageDragType) }.compactMap { UInt32($0) }
        guard !uids.isEmpty else { return false }
        node.store.move(uids: uids, from: source, to: destination) { [weak self] error in
            self?.presentFailure("메일을 옮기지 못했습니다", error)
        }
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? MailboxCellView ?? MailboxCellView()
        cell.identifier = Self.cellID
        let unread = node.store.inboxUnread
        cell.configure(node, badge: node.mailbox?.role == .inbox && unread > 0 ? "\(unread)" : "")
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.mailbox != nil || node.isAccount
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode else { return }
        accountRowStore = node.isAccount ? node.store : nil
        // 계정 줄은 그 계정의 받은편지함을 연다.
        if let target = node.isAccount ? node.store.inboxMailbox : node.mailbox {
            manager.select(target, in: node.store)
        }
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
