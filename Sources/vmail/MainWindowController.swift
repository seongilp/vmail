import AppKit
import MailCore

private extension NSToolbarItem.Identifier {
    static let compose = NSToolbarItem.Identifier("compose")
    static let refresh = NSToolbarItem.Identifier("refresh")
    static let reply = NSToolbarItem.Identifier("reply")
    static let flag = NSToolbarItem.Identifier("flag")
    static let trash = NSToolbarItem.Identifier("trash")
    static let search = NSToolbarItem.Identifier("search")
}

/// 3단(사서함 · 목록 · 본문) 메인 창
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate,
                                  NSUserInterfaceValidations, MessageListDelegate {
    private let store: MailStore
    private let sidebar: SidebarViewController
    private let list: MessageListViewController
    private let detail: MessageDetailViewController
    private var searchItem: NSSearchToolbarItem?
    private var accountSheet: AccountSheetController?
    private var composeControllers: [ComposeWindowController] = []

    init(store: MailStore) {
        self.store = store
        sidebar = SidebarViewController(store: store)
        list = MessageListViewController(store: store)
        detail = MessageDetailViewController(store: store)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 780, height: 420)
        window.toolbarStyle = .unified
        window.title = "vmail"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 260
        let listItem = NSSplitViewItem(contentListWithViewController: list)
        listItem.minimumThickness = 260
        listItem.maximumThickness = 460
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 340
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(listItem)
        split.addSplitViewItem(detailItem)
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1080, height: 660))
        window.center()
        window.setFrameAutosaveName("MainWindow")

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        list.delegate = self
        let center = NotificationCenter.default
        for name in [MailStore.selectionDidChange, MailStore.unreadDidChange, MailStore.accountDidChange] {
            center.addObserver(self, selector: #selector(updateTitle), name: name, object: store)
        }
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    @objc private func updateTitle() {
        window?.title = store.selectedMailbox?.displayName ?? "vmail"
        var subtitle = store.account?.email ?? ""
        if store.selectedMailbox?.role == .inbox, store.inboxUnread > 0 {
            subtitle = "읽지 않은 메일 \(store.inboxUnread)개"
        }
        window?.subtitle = subtitle
    }

    func showAccountSheet() {
        guard let window, accountSheet == nil else { return }
        let sheet = AccountSheetController(store: store)
        accountSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.accountSheet = nil
            self?.list.focus()
        }
    }

    // MARK: - MessageListDelegate

    func messageList(_ list: MessageListViewController, didSelect envelopes: [Envelope]) {
        detail.show(envelopes, in: store.selectedMailbox)
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - 액션

    @objc func showMainWindow(_ sender: Any?) {
        showWindow(sender)
    }

    @objc func composeMessage(_ sender: Any?) {
        guard let account = store.account else { return showAccountSheet() }
        openCompose(ComposeDraft(from: account.address))
    }

    @objc func replyMessage(_ sender: Any?) {
        reply(all: false)
    }

    @objc func replyAllMessage(_ sender: Any?) {
        reply(all: true)
    }

    private func reply(all: Bool) {
        guard let account = store.account, let current = detail.current else { return }
        openCompose(ComposeDraft.reply(to: current.envelope, message: current.message, account: account, all: all))
    }

    private func openCompose(_ draft: ComposeDraft) {
        let controller = ComposeWindowController(store: store, draft: draft)
        controller.onClose = { [weak self, weak controller] in
            self?.composeControllers.removeAll { $0 === controller }
        }
        composeControllers.append(controller)
        controller.showWindow(nil)
    }

    @objc func refreshMailbox(_ sender: Any?) {
        store.loadMailboxes()
        store.refresh()
    }

    @objc func deleteMessage(_ sender: Any?) {
        guard let mailbox = store.selectedMailbox else { return }
        let targets = list.selectedEnvelopes
        guard !targets.isEmpty else { return }
        store.delete(targets, in: mailbox) { [weak self] error in
            self?.presentFailure("메일을 삭제하지 못했습니다", error)
        }
    }

    @objc func toggleRead(_ sender: Any?) {
        toggle("\\Seen", failureTitle: "읽음 상태를 바꾸지 못했습니다")
    }

    @objc func toggleFlag(_ sender: Any?) {
        toggle("\\Flagged", failureTitle: "깃발을 바꾸지 못했습니다")
    }

    /// 선택한 메일 중 하나라도 플래그가 없으면 모두 켜고, 전부 켜져 있으면 끈다.
    private func toggle(_ flag: String, failureTitle: String) {
        guard let mailbox = store.selectedMailbox else { return }
        let targets = list.selectedEnvelopes
        guard !targets.isEmpty else { return }
        let turnOn = targets.contains { !$0.hasFlag(flag) }
        store.setFlag(flag, on: turnOn, envelopes: targets, in: mailbox) { [weak self] error in
            self?.presentFailure(failureTitle, error)
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let field = searchItem?.searchField else { return }
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSSearchField else { return }
        list.setFilter(field.stringValue)
    }

    private func presentFailure(_ title: String, _ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: - 유효성 (메뉴 + 툴바 공통)

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(replyMessage(_:)), #selector(replyAllMessage(_:)):
            return detail.current != nil
        case #selector(toggleRead(_:)):
            let targets = list.selectedEnvelopes
            // 지금 누르면 일어날 일을 메뉴 제목으로 보여준다.
            (item as? NSMenuItem)?.title = targets.contains { !$0.isSeen } || targets.isEmpty
                ? "읽음으로 표시" : "읽지 않음으로 표시"
            return !targets.isEmpty
        case #selector(toggleFlag(_:)):
            let targets = list.selectedEnvelopes
            (item as? NSMenuItem)?.title = targets.contains { !$0.isFlagged } || targets.isEmpty
                ? "깃발 표시" : "깃발 지우기"
            return !targets.isEmpty
        case #selector(deleteMessage(_:)):
            return !list.selectedEnvelopes.isEmpty
        case #selector(refreshMailbox(_:)):
            return store.account != nil
        default:
            return true
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .refresh, .compose, .flexibleSpace, .reply, .flag, .trash, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .compose: return button(id, "새로운 메일", "square.and.pencil", #selector(composeMessage(_:)))
        case .refresh: return button(id, "메일 가져오기", "arrow.clockwise", #selector(refreshMailbox(_:)))
        case .reply: return button(id, "답장", "arrowshape.turn.up.left", #selector(replyMessage(_:)))
        case .flag: return button(id, "깃발", "star", #selector(toggleFlag(_:)))
        case .trash: return button(id, "삭제", "trash", #selector(deleteMessage(_:)))
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "검색"
            item.searchField.delegate = self
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }
}
