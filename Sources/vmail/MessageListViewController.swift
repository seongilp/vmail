import AppKit
import MailCore

protocol MessageListDelegate: AnyObject {
    func messageList(_ list: MessageListViewController, didSelect envelopes: [Envelope])
    func messageList(_ list: MessageListViewController, didDoubleClick envelope: Envelope)
}

private final class MessageTableView: NSTableView {
    /// 우클릭한 줄이 선택에 없으면 그 줄만 선택한 뒤 메뉴를 띄운다.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    /// ←/→ 로 대화를 접고 펼칠 때 호출된다 (true: 펼치기). 처리했으면 true를 돌려준다.
    var onArrow: ((Bool) -> Bool)?

    /// Delete 키를 삭제 액션으로 바꿔 응답자 체인에 올린다.
    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]   // delete, forward delete
        if event.keyCode == 124 || event.keyCode == 123, onArrow?(event.keyCode == 124) == true { return }
        if deleteKeys.contains(event.keyCode) {
            NSApp.sendAction(#selector(MainWindowController.deleteMessage(_:)), to: nil, from: self)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 선택된 사서함의 메시지 목록. 입력 중에는 불러온 목록을 걸러 보여주고, Enter를 누르면 서버 전체를 검색한다.
final class MessageListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("message")
    private static let loadMoreThreshold: CGFloat = 300

    weak var delegate: MessageListDelegate?
    private let manager: AccountManager
    private let tableView = MessageTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var rows: [MessageRow] = []
    /// 펼쳐 둔 대화
    private var expandedThreads: Set<UInt32> = []
    private var filter = ""
    private var isReloading = false
    /// 서버 검색 결과 (nil이면 일반 목록)
    private var searchResults: [Envelope]?
    private var searchQuery = ""
    private var isSearching = false
    private var searchError: String?
    private(set) var unreadOnly = false

    private var store: MailStore? { manager.current }

    init(manager: AccountManager, contextMenu: NSMenu) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        tableView.menu = contextMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    /// 동작(삭제·읽음·이동 등)의 대상. 접힌 대화를 고르면 그 대화의 메일 전부가 들어간다.
    var selectedEnvelopes: [Envelope] {
        var seen = Set<UInt32>()
        return selectedRows.flatMap(\.targets).filter { seen.insert($0.uid).inserted }
    }

    /// 선택한 줄에 보이는 메일 (본문 표시용)
    private var selectedRowEnvelopes: [Envelope] {
        selectedRows.map(\.envelope)
    }

    private var selectedRows: [MessageRow] {
        tableView.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = MessageCellView.rowHeight
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.onArrow = { [weak self] expand in self?.setSelectedThread(expanded: expand) ?? false }
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityLabel("메시지")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(statusLabel)
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(mailboxChanged), name: AccountManager.currentDidChange, object: manager)
        center.addObserver(self, selector: #selector(storeSelectionChanged(_:)), name: MailStore.selectionDidChange, object: nil)
        center.addObserver(self, selector: #selector(messagesChanged(_:)), name: MailStore.messagesDidChange, object: nil)
        center.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        reload(keepSelection: false)
    }

    /// 글꼴·굵게 표시 등 보기 설정이 바뀌면 목록을 다시 그린다.
    @objc private func preferencesChanged() {
        tableView.rowHeight = MessageCellView.rowHeight
        if let store, let mailbox = store.selectedMailbox { store.ensurePreviews(for: mailbox) }
        reload(keepSelection: true)
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - 검색 / 필터

    /// 입력 중: 불러온 목록만 즉시 거른다.
    func setFilter(_ text: String) {
        filter = text.trimmingCharacters(in: .whitespaces)
        if filter != searchQuery { clearSearch() }
        reload(keepSelection: true)
    }

    /// Enter: 서버에서 사서함 전체를 검색한다.
    func submitSearch(_ text: String, field: SearchField = .text) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard let store, let mailbox = store.selectedMailbox, !query.isEmpty else {
            clearSearch()
            reload(keepSelection: true)
            return
        }
        filter = query
        searchQuery = query
        searchResults = []
        searchError = nil
        isSearching = true
        reload(keepSelection: false)
        store.search(query, field: field, in: mailbox) { [weak self] result in
            guard let self, self.searchQuery == query, self.store === store, store.selectedMailbox == mailbox else { return }
            self.isSearching = false
            switch result {
            case .success(let envelopes): self.searchResults = envelopes
            case .failure(let error): self.searchError = error.localizedDescription
            }
            self.reload(keepSelection: false)
        }
    }

    func toggleUnreadOnly() {
        unreadOnly.toggle()
        reload(keepSelection: true)
    }

    private func clearSearch() {
        searchResults = nil
        searchQuery = ""
        searchError = nil
        isSearching = false
    }

    // MARK: - 갱신

    @objc private func mailboxChanged() {
        clearSearch()
        reload(keepSelection: false)
        tableView.scrollRowToVisible(0)
    }

    @objc private func storeSelectionChanged(_ note: Notification) {
        guard note.object as? MailStore === store else { return }
        mailboxChanged()
    }

    @objc private func messagesChanged(_ note: Notification) {
        guard note.object as? MailStore === store,
              note.userInfo?["path"] as? String == store?.selectedMailbox?.path else { return }
        // 검색 결과에도 같은 변경(읽음·삭제 등)을 반영한다.
        if let results = searchResults, let mutation = note.userInfo?["mutation"] as? MessageMutation {
            searchResults = mutation.apply(to: results)
        }
        reload(keepSelection: true)
    }

    private func reload(keepSelection: Bool) {
        let previous = Set(keepSelection ? selectedRowEnvelopes.map(\.uid) : [])
        let previousFirstRow = tableView.selectedRowIndexes.first
        let state = store.flatMap { s in s.selectedMailbox.map(s.state(for:)) } ?? MailboxListState()
        var base = searchResults ?? (filter.isEmpty ? state.envelopes : state.envelopes.filter(matchesFilter))
        if unreadOnly { base = base.filter { !$0.isSeen || previous.contains($0.uid) } }
        rows = makeRows(base)

        isReloading = true
        tableView.reloadData()
        var restored = IndexSet(rows.indices.filter { previous.contains(rows[$0].envelope.uid) })
        // 선택했던 메일이 사라졌으면(삭제·이동) 그 자리에 올라온 다음 메일을 선택해 흐름이 끊기지 않게 한다.
        if restored.isEmpty, keepSelection, Preferences.selectNextAfterRemoval, let row = previousFirstRow, !rows.isEmpty {
            restored = [min(row, rows.count - 1)]
        }
        tableView.selectRowIndexes(restored, byExtendingSelection: false)
        if keepSelection, let first = restored.first { tableView.scrollRowToVisible(first) }
        isReloading = false

        updateStatus(state)
        if Set(selectedRowEnvelopes.map(\.uid)) != previous || !keepSelection {
            delegate?.messageList(self, didSelect: selectedRowEnvelopes)
        }
    }

    // MARK: - 대화 묶기

    /// 대화로 묶기 설정에 따라 목록 줄을 만든다. 펼친 대화는 머리 줄 아래에 나머지 메일을 하위 줄로 넣는다.
    private func makeRows(_ envelopes: [Envelope]) -> [MessageRow] {
        guard Preferences.groupByConversation else {
            return envelopes.map { MessageRow(envelope: $0, targets: [$0], threadCount: 1, threadKey: $0.uid, isExpanded: false, isChild: false) }
        }
        var result: [MessageRow] = []
        for group in ThreadGrouper.group(envelopes) {
            guard let latest = group.first else { continue }
            let key = group.map(\.uid).min() ?? latest.uid
            let expanded = group.count > 1 && expandedThreads.contains(key)
            result.append(MessageRow(envelope: latest, targets: expanded ? [latest] : group, threadCount: group.count,
                                     threadKey: key, isExpanded: expanded, isChild: false))
            guard expanded else { continue }
            for member in group.dropFirst() {
                result.append(MessageRow(envelope: member, targets: [member], threadCount: group.count,
                                         threadKey: key, isExpanded: true, isChild: true))
            }
        }
        return result
    }

    private func toggleThread(_ key: UInt32) {
        expandedThreads = expandedThreads.contains(key) ? expandedThreads.subtracting([key]) : expandedThreads.union([key])
        reload(keepSelection: true)
    }

    /// ←/→ 키: 선택한 대화를 접거나 펼친다. 대화가 아니거나 이미 그 상태면 false.
    private func setSelectedThread(expanded: Bool) -> Bool {
        guard let row = selectedRows.first, row.threadCount > 1, row.isExpanded != expanded else { return false }
        toggleThread(row.threadKey)
        return true
    }

    private func matchesFilter(_ envelope: Envelope) -> Bool {
        let haystack = ([envelope.subject] + (envelope.from + envelope.to).flatMap { [$0.name ?? "", $0.email] })
        return haystack.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func updateStatus(_ state: MailboxListState) {
        var message = ""
        var busy = false
        if store == nil {
            message = "계정을 추가하면 메일이 여기에 표시됩니다"
        } else if store?.selectedMailbox == nil {
            message = store?.mailboxError ?? "사서함을 불러오는 중…"
        } else if isSearching {
            message = "서버에서 검색하는 중…"
            busy = true
        } else if rows.isEmpty {
            if let error = searchError ?? state.error {
                message = error
            } else if searchResults == nil, !state.hasLoaded {
                message = "메일을 불러오는 중…"
                busy = true
            } else if !filter.isEmpty {
                message = searchResults == nil
                    ? "불러온 메일 중에는 ‘\(filter)’ 결과가 없습니다.\nEnter를 누르면 서버 전체를 검색합니다."
                    : "‘\(filter)’ 검색 결과가 없습니다"
            } else {
                message = unreadOnly ? "읽지 않은 메일이 없습니다" : "메일이 없습니다"
            }
        }
        statusLabel.stringValue = message
        statusLabel.isHidden = message.isEmpty
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func scrolled() {
        guard filter.isEmpty, searchResults == nil, let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        if document.bounds.height - visible.maxY < Self.loadMoreThreshold { store?.loadMore() }
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        delegate?.messageList(self, didDoubleClick: rows[row].envelope)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? MessageCellView ?? MessageCellView()
        cell.identifier = Self.cellID
        let role = store?.selectedMailbox?.role
        let item = rows[row]
        let preview = store.flatMap { s in s.selectedMailbox.flatMap { s.preview(for: item.envelope, in: $0) } }
        cell.configure(item, showRecipient: role == .sent || role == .drafts, preview: preview)
        cell.onToggleThread = { [weak self] in self?.toggleThread(item.threadKey) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        delegate?.messageList(self, didSelect: selectedRowEnvelopes)
    }

    /// 사이드바의 사서함으로 끌어 옮길 수 있게 UID를 싣는다.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(rows[row].envelope.uid)", forType: SidebarViewController.messageDragType)
        return item
    }
}
