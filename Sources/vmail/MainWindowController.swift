import AppKit
import MailCore

private extension NSToolbarItem.Identifier {
    static let compose = NSToolbarItem.Identifier("compose")
    static let refresh = NSToolbarItem.Identifier("refresh")
    static let reply = NSToolbarItem.Identifier("reply")
    static let forward = NSToolbarItem.Identifier("forward")
    static let archive = NSToolbarItem.Identifier("archive")
    static let flag = NSToolbarItem.Identifier("flag")
    static let trash = NSToolbarItem.Identifier("trash")
    static let search = NSToolbarItem.Identifier("search")
}

/// ‘이동’ 하위 메뉴: 현재 계정의 사서함 목록을 그때그때 채운다.
final class MailboxMenu: NSObject, NSMenuDelegate {
    private let manager: AccountManager

    init(manager: AccountManager) {
        self.manager = manager
    }

    func makeSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let store = manager.current else { return }
        let order = MailboxRole.allCases
        let targets = store.mailboxes.filter { $0 != store.selectedMailbox && $0.role != .flagged && $0.role != .important }
            .sorted { (order.firstIndex(of: $0.role) ?? 0, $0.name) < (order.firstIndex(of: $1.role) ?? 0, $1.name) }
        for mailbox in targets {
            let title = mailbox.role == .other ? mailbox.name : mailbox.displayName
            let item = NSMenuItem(title: title, action: #selector(MainWindowController.moveToMailbox(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: mailbox.symbolName, accessibilityDescription: nil)
            item.representedObject = mailbox.path
            menu.addItem(item)
        }
    }
}

/// 3단(사서함 · 목록 · 본문) 메인 창. 메뉴·툴바 액션은 MainWindowController+Actions 에 있다.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate,
                                  NSUserInterfaceValidations, MessageListDelegate {
    let manager: AccountManager
    let mailboxMenu: MailboxMenu
    let sidebar: SidebarViewController
    let list: MessageListViewController
    let detail = MessageDetailViewController()
    var searchItem: NSSearchToolbarItem?
    var composeControllers: [ComposeWindowController] = []

    var store: MailStore? { manager.current }

    init(manager: AccountManager, mailboxMenu: MailboxMenu) {
        self.manager = manager
        self.mailboxMenu = mailboxMenu
        sidebar = SidebarViewController(manager: manager)
        list = MessageListViewController(manager: manager, contextMenu: Self.contextMenu(mailboxMenu))

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
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
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
        center.addObserver(self, selector: #selector(updateTitle), name: AccountManager.currentDidChange, object: manager)
        center.addObserver(self, selector: #selector(updateTitle), name: MailStore.selectionDidChange, object: nil)
        center.addObserver(self, selector: #selector(updateTitle), name: MailStore.unreadDidChange, object: nil)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    /// 메시지 목록 우클릭 메뉴. 액션은 nil 타깃으로 보내 이 컨트롤러가 처리하고 제목·활성 여부도 정한다.
    private static func contextMenu(_ mailboxMenu: MailboxMenu) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "답장", action: #selector(replyMessage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "모두에게 답장", action: #selector(replyAllMessage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "전달", action: #selector(forwardMessage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "읽지 않음으로 표시", action: #selector(toggleRead(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "깃발 표시", action: #selector(toggleFlag(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "보관", action: #selector(archiveMessage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "스팸으로 이동", action: #selector(junkMessage(_:)), keyEquivalent: "")
        let move = NSMenuItem(title: "이동", action: nil, keyEquivalent: "")
        move.submenu = mailboxMenu.makeSubmenu()
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(withTitle: "삭제", action: #selector(deleteMessage(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func updateTitle() {
        window?.title = store?.selectedMailbox?.displayName ?? "vmail"
        var subtitle = store?.account.email ?? ""
        if let store, store.selectedMailbox?.role == .inbox, store.inboxUnread > 0 {
            subtitle = "\(store.account.email) · 읽지 않은 메일 \(store.inboxUnread)개"
        }
        window?.subtitle = subtitle
    }

    func showAccountSheet(editing: MailStore? = nil) {
        guard let window else { return }
        AccountSheetController.present(on: window, manager: manager, editing: editing)
    }

    func presentFailure(_ title: String, _ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: - MessageListDelegate

    func messageList(_ list: MessageListViewController, didSelect envelopes: [Envelope]) {
        detail.show(envelopes, in: store?.selectedMailbox, store: store)
        window?.toolbar?.validateVisibleItems()
    }

    /// 임시보관함의 메일은 더블클릭하면 이어서 작성한다.
    func messageList(_ list: MessageListViewController, didDoubleClick envelope: Envelope) {
        guard let store, let mailbox = store.selectedMailbox, mailbox.role == .drafts else { return }
        store.loadBody(envelope, in: mailbox) { [weak self] result in
            switch result {
            case .success(let message):
                self?.openCompose(.editing(envelope, in: mailbox, message: message, account: store.account), store: store)
            case .failure(let error):
                self?.presentFailure("임시 저장본을 열지 못했습니다", error)
            }
        }
    }

    // MARK: - 검색 필드

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSSearchField else { return }
        list.setFilter(field.stringValue)
    }

    @objc func submitSearch(_ sender: NSSearchField) {
        list.submitSearch(sender.stringValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .refresh, .compose, .flexibleSpace,
         .reply, .forward, .archive, .flag, .trash, .search]
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
        case .forward: return button(id, "전달", "arrowshape.turn.up.right", #selector(forwardMessage(_:)))
        case .archive: return button(id, "보관", "archivebox", #selector(archiveMessage(_:)))
        case .flag: return button(id, "깃발", "star", #selector(toggleFlag(_:)))
        case .trash: return button(id, "삭제", "trash", #selector(deleteMessage(_:)))
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "검색 (Enter: 서버 전체)"
            item.searchField.delegate = self
            item.searchField.sendsWholeSearchString = true   // Enter를 눌렀을 때만 액션
            item.searchField.target = self
            item.searchField.action = #selector(submitSearch(_:))
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
