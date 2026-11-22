import AppKit
import MailCore

extension Mailbox {
    /// 사이드바에 보여줄 이름
    var displayName: String {
        switch role {
        case .inbox: return "받은편지함"
        case .flagged: return "별표편지함"
        case .drafts: return "임시보관함"
        case .sent: return "보낸편지함"
        case .all: return "전체보관함"
        case .junk: return "스팸편지함"
        case .trash: return "휴지통"
        case .other: return leafName
        }
    }

    var symbolName: String {
        switch role {
        case .inbox: return "tray"
        case .flagged: return "star"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .all: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .other: return "folder"
        }
    }

    /// 사용자 폴더의 중첩 깊이 (역할이 있는 사서함은 항상 최상위로 보여준다)
    var indentLevel: Int { role == .other ? max(0, components.count - 1) : 0 }
}

/// 사서함 목록(소스 리스트)
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("mailbox")
    private static let indentWidth: CGFloat = 14

    private let store: MailStore
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var isReloading = false

    init(store: MailStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    override func loadView() {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("사서함")

        let scroll = NSScrollView()
        scroll.documentView = tableView
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
        center.addObserver(self, selector: #selector(reload), name: MailStore.selectionDidChange, object: store)
        reload()
    }

    @objc private func reload() {
        isReloading = true
        tableView.reloadData()
        if let selected = store.selectedMailbox,
           let row = store.mailboxes.firstIndex(where: { $0.path == selected.path }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isReloading = false

        if store.account == nil {
            statusLabel.stringValue = "계정이 없습니다"
        } else if store.mailboxes.isEmpty {
            statusLabel.stringValue = store.mailboxError ?? "사서함을 불러오는 중…"
        } else {
            statusLabel.stringValue = ""
        }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.mailboxes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? MailboxCellView ?? MailboxCellView()
        cell.identifier = Self.cellID
        cell.configure(store.mailboxes[row], indentWidth: Self.indentWidth)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, tableView.selectedRow >= 0 else { return }
        store.select(store.mailboxes[tableView.selectedRow])
    }
}

private final class MailboxCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        let leading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    func configure(_ mailbox: Mailbox, indentWidth: CGFloat) {
        icon.image = NSImage(systemSymbolName: mailbox.symbolName, accessibilityDescription: nil)
        label.stringValue = mailbox.displayName
        leading?.constant = 4 + CGFloat(mailbox.indentLevel) * indentWidth
    }
}
