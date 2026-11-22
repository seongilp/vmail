import AppKit
import MailCore

/// 사이드바 우클릭 메뉴: 가져오기, 모두 읽음, 비우기, 폴더 관리, 계정 관리
extension SidebarViewController {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }

        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }

        if node.mailbox != nil || node.isAccount {
            add("새로운 메일 가져오기", #selector(menuRefresh(_:)))
        }
        if let mailbox = node.mailbox {
            add("모두 읽음으로 표시", #selector(menuMarkAllRead(_:)))
            if mailbox.role == .trash || mailbox.role == .junk {
                add("\(mailbox.displayName) 비우기…", #selector(menuEmpty(_:)))
            }
        }
        menu.addItem(.separator())
        add("새 폴더…", #selector(menuNewFolder(_:)))
        if node.mailbox?.role == .other {
            add("이름 변경…", #selector(menuRenameFolder(_:)))
            add("폴더 삭제…", #selector(menuDeleteFolder(_:)))
        }
        if node.isAccount {
            menu.addItem(.separator())
            let settings = NSMenuItem(title: "계정 설정…", action: #selector(AppDelegate.showAccounts(_:)), keyEquivalent: "")
            menu.addItem(settings)
            add("이 계정 제거…", #selector(menuRemoveAccount(_:)))
        }
        if !node.children.isEmpty {
            menu.addItem(.separator())
            add(outlineView.isItemExpanded(node) ? "접기" : "펼치기", #selector(menuToggle(_:)))
        }
    }

    private func node(_ sender: NSMenuItem) -> SidebarNode? {
        sender.representedObject as? SidebarNode
    }

    private func mailbox(_ node: SidebarNode) -> Mailbox? {
        node.isAccount ? node.store.inboxMailbox : node.mailbox
    }

    @objc private func menuRefresh(_ sender: NSMenuItem) {
        guard let node = node(sender), let mailbox = mailbox(node) else { return }
        node.store.loadMailboxes()
        manager.select(mailbox, in: node.store)
    }

    @objc private func menuMarkAllRead(_ sender: NSMenuItem) {
        guard let node = node(sender), let mailbox = node.mailbox else { return }
        node.store.markAllRead(in: mailbox) { [weak self] error in
            self?.presentFailure("읽음으로 표시하지 못했습니다", error)
        }
    }

    @objc private func menuEmpty(_ sender: NSMenuItem) {
        guard let node = node(sender), let mailbox = node.mailbox else { return }
        confirm("\(mailbox.displayName)을(를) 비울까요?",
                "이 사서함의 모든 메일이 서버에서 완전히 삭제되며 되돌릴 수 없습니다.", button: "비우기") { [weak self] in
            node.store.empty(mailbox) { error in
                self?.presentFailure("사서함을 비우지 못했습니다", error)
            }
        }
    }

    @objc private func menuNewFolder(_ sender: NSMenuItem) {
        guard let node = node(sender) else { return }
        // 사용자 폴더 위에서 열면 그 하위에, 그 외에는 최상위에 만든다.
        let parent = node.mailbox?.role == .other ? node.mailbox : nil
        let message = parent.map { "‘\($0.leafName)’ 안에 새 폴더를 만듭니다." } ?? "\(node.store.account.email)에 새 폴더를 만듭니다."
        prompt("새 폴더", message, initial: "", button: "만들기") { [weak self] name in
            node.store.createFolder(named: name, under: parent) { error in
                if let error { self?.presentFailure("폴더를 만들지 못했습니다", error) }
            }
        }
    }

    @objc private func menuRenameFolder(_ sender: NSMenuItem) {
        guard let node = node(sender), let mailbox = node.mailbox else { return }
        prompt("폴더 이름 변경", "새 이름을 입력하세요.", initial: mailbox.leafName, button: "변경") { [weak self] name in
            node.store.renameFolder(mailbox, to: name) { error in
                if let error { self?.presentFailure("이름을 바꾸지 못했습니다", error) }
            }
        }
    }

    @objc private func menuDeleteFolder(_ sender: NSMenuItem) {
        guard let node = node(sender), let mailbox = node.mailbox else { return }
        confirm("‘\(mailbox.leafName)’ 폴더를 삭제할까요?",
                "폴더와 그 안의 메일이 서버에서 삭제되며 되돌릴 수 없습니다.", button: "삭제") { [weak self] in
            node.store.deleteFolder(mailbox) { error in
                if let error { self?.presentFailure("폴더를 삭제하지 못했습니다", error) }
            }
        }
    }

    @objc private func menuRemoveAccount(_ sender: NSMenuItem) {
        guard let node = node(sender) else { return }
        confirm("\(node.store.account.email) 계정을 제거할까요?",
                "이 Mac에 저장된 비밀번호와 캐시가 삭제됩니다. 서버의 메일은 그대로 남습니다.", button: "제거") { [weak self] in
            self?.manager.remove(node.store)
        }
    }

    @objc private func menuToggle(_ sender: NSMenuItem) {
        if let node = node(sender) { toggle(node) }
    }

    // MARK: - 대화 상자

    private func confirm(_ title: String, _ message: String, button: String, action: @escaping () -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "취소")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }

    private func prompt(_ title: String, _ message: String, initial: String, button: String,
                        action: @escaping (String) -> Void) {
        guard let window = view.window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action(field.stringValue) }
        }
    }
}
