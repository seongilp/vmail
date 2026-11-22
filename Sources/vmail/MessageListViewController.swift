import AppKit
import MailCore

protocol MessageListDelegate: AnyObject {
    func messageList(_ list: MessageListViewController, didSelect envelopes: [Envelope])
}

/// Delete 키를 삭제 액션으로 바꿔 응답자 체인에 올린다.
private final class MessageTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]   // delete, forward delete
        if deleteKeys.contains(event.keyCode) {
            NSApp.sendAction(#selector(MainWindowController.deleteMessage(_:)), to: nil, from: self)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 선택된 사서함의 메시지 목록
final class MessageListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("message")
    private static let loadMoreThreshold: CGFloat = 300

    weak var delegate: MessageListDelegate?
    private let store: MailStore
    private let tableView = MessageTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var rows: [Envelope] = []
    private var filter = ""
    private var isReloading = false

    init(store: MailStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    var selectedEnvelopes: [Envelope] {
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
        center.addObserver(self, selector: #selector(selectionChanged), name: MailStore.selectionDidChange, object: store)
        center.addObserver(self, selector: #selector(messagesChanged(_:)), name: MailStore.messagesDidChange, object: store)
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        reload(keepSelection: false)
    }

    func setFilter(_ text: String) {
        filter = text.trimmingCharacters(in: .whitespaces)
        reload(keepSelection: true)
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - 갱신

    @objc private func selectionChanged() {
        reload(keepSelection: false)
        tableView.scrollRowToVisible(0)
    }

    @objc private func messagesChanged(_ note: Notification) {
        guard note.userInfo?["path"] as? String == store.selectedMailbox?.path else { return }
        reload(keepSelection: true)
    }

    private func reload(keepSelection: Bool) {
        let previous = Set(keepSelection ? selectedEnvelopes.map(\.uid) : [])
        let state = store.selectedMailbox.map(store.state(for:)) ?? MailboxListState()
        rows = filter.isEmpty ? state.envelopes : state.envelopes.filter(matchesFilter)

        isReloading = true
        tableView.reloadData()
        let restored = IndexSet(rows.indices.filter { previous.contains(rows[$0].uid) })
        tableView.selectRowIndexes(restored, byExtendingSelection: false)
        isReloading = false

        updateStatus(state)
        // 선택이 사라졌거나(삭제) 플래그가 바뀐 경우를 상세 화면에 반영한다.
        if Set(selectedEnvelopes.map(\.uid)) != previous || !keepSelection {
            delegate?.messageList(self, didSelect: selectedEnvelopes)
        }
    }

    private func matchesFilter(_ envelope: Envelope) -> Bool {
        let haystack = ([envelope.subject] + (envelope.from + envelope.to).flatMap { [$0.name ?? "", $0.email] })
        return haystack.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func updateStatus(_ state: MailboxListState) {
        var message = ""
        var busy = false
        if store.account == nil {
            message = "계정을 추가하면 메일이 여기에 표시됩니다"
        } else if store.selectedMailbox == nil {
            message = store.mailboxError ?? "사서함을 선택하세요"
        } else if rows.isEmpty {
            if let error = state.error {
                message = error
            } else if !state.hasLoaded {
                message = "메일을 불러오는 중…"
                busy = true
            } else if !filter.isEmpty {
                message = "‘\(filter)’ 검색 결과가 없습니다"
            } else {
                message = "메일이 없습니다"
            }
        }
        statusLabel.stringValue = message
        statusLabel.isHidden = message.isEmpty
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func scrolled() {
        guard filter.isEmpty, let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        if document.bounds.height - visible.maxY < Self.loadMoreThreshold { store.loadMore() }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? MessageCellView ?? MessageCellView()
        cell.identifier = Self.cellID
        let role = store.selectedMailbox?.role
        cell.configure(rows[row], showRecipient: role == .sent || role == .drafts)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        delegate?.messageList(self, didSelect: selectedEnvelopes)
    }
}
