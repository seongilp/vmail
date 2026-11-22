import Foundation
import MailCore

extension Mailbox {
    /// 사이드바에 보여줄 이름
    var displayName: String {
        switch role {
        case .inbox: return "받은편지함"
        case .flagged: return "별표편지함"
        case .important: return "중요"
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
        case .important: return "exclamationmark.circle"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .all: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .other: return "folder"
        }
    }
}

/// 사이드바 트리의 한 줄. NSOutlineView가 항목을 참조로 식별하므로 클래스다.
final class SidebarNode {
    enum Kind {
        case account            // 최상단 계정 줄
        case mailbox(Mailbox)   // 선택 가능한 사서함
        case container          // 하위 폴더만 묶는 줄 (서버에 사서함 없음)
    }

    /// 접힘 상태를 기억하기 위한 고정 식별자
    let key: String
    let title: String
    let symbolName: String
    let kind: Kind
    /// 이 줄이 속한 계정의 스토어
    let store: MailStore
    private(set) var children: [SidebarNode]

    init(store: MailStore, key: String, title: String, symbolName: String, kind: Kind, children: [SidebarNode] = []) {
        self.store = store
        self.key = key
        self.title = title
        self.symbolName = symbolName
        self.kind = kind
        self.children = children
    }

    var mailbox: Mailbox? {
        if case .mailbox(let mailbox) = kind { return mailbox }
        return nil
    }

    var isAccount: Bool {
        if case .account = kind { return true }
        return false
    }

    fileprivate func adding(_ child: SidebarNode) {
        children.append(child)
    }

    fileprivate func child(titled title: String) -> SidebarNode? {
        children.first { $0.title == title && !$0.isSpecial }
    }

    private var isSpecial: Bool {
        if let mailbox { return mailbox.role != .other }
        return false
    }
}

/// 계정 → 기본 사서함 → 사용자 폴더 계층으로 트리를 만든다.
enum SidebarTree {
    static func build(store: MailStore) -> SidebarNode {
        let email = store.account.email
        let root = SidebarNode(store: store, key: "\(email)|account", title: email,
                               symbolName: "person.crop.circle", kind: .account)

        // 기본 사서함은 서버 경로와 상관없이 계정 바로 아래에, 정해진 순서로 둔다.
        let order = MailboxRole.allCases
        let specials = store.mailboxes.filter { $0.role != .other }
            .sorted { (order.firstIndex(of: $0.role) ?? 0) < (order.firstIndex(of: $1.role) ?? 0) }
        for mailbox in specials {
            root.adding(SidebarNode(store: store, key: "\(email)|role:\(mailbox.role.rawValue)", title: mailbox.displayName,
                                    symbolName: mailbox.symbolName, kind: .mailbox(mailbox)))
        }

        // 사용자 폴더는 경로 구성 요소를 따라 계층으로 넣는다. 부모가 먼저 오도록 이름순 정렬.
        let folders = store.mailboxes.filter { $0.role == .other }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for mailbox in folders {
            insert(mailbox, into: root)
        }
        return root
    }

    private static func insert(_ mailbox: Mailbox, into root: SidebarNode) {
        let parts = mailbox.components.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        let prefixKey = "\(root.store.account.email)|folder:"
        var parent = root
        var prefix: [String] = []
        for part in parts.dropLast() {
            prefix.append(part)
            if let existing = parent.child(titled: part) {
                parent = existing
            } else {
                let container = SidebarNode(store: root.store, key: prefixKey + prefix.joined(separator: "\u{1F}"),
                                            title: part, symbolName: "folder", kind: .container)
                parent.adding(container)
                parent = container
            }
        }
        parent.adding(SidebarNode(store: root.store, key: prefixKey + parts.joined(separator: "\u{1F}"),
                                  title: parts[parts.count - 1], symbolName: "folder", kind: .mailbox(mailbox)))
    }
}
