import AppKit
import MailCore

/// 메뉴·툴바·우클릭 메뉴가 공유하는 액션과 유효성 검사
extension MainWindowController {
    @objc func showMainWindow(_ sender: Any?) {
        showWindow(sender)
    }

    // MARK: - 작성

    @objc func composeMessage(_ sender: Any?) {
        // 설정에서 정한 계정이 있으면 그 계정으로, 없으면 지금 보고 있는 계정으로 보낸다.
        let preferred = manager.stores.first { $0.account.email.lowercased() == Preferences.defaultAccountEmail.lowercased() }
        guard let store = preferred ?? store else { return showAccountSheet() }
        openCompose(ComposeDraft(from: store.account.address), store: store)
    }

    @objc func replyMessage(_ sender: Any?) {
        guard let current = detail.current else { return }
        openCompose(.reply(to: current.envelope, message: current.message, account: current.store.account, all: false),
                    store: current.store)
    }

    @objc func replyAllMessage(_ sender: Any?) {
        guard let current = detail.current else { return }
        openCompose(.reply(to: current.envelope, message: current.message, account: current.store.account, all: true),
                    store: current.store)
    }

    @objc func forwardMessage(_ sender: Any?) {
        guard let current = detail.current else { return }
        openCompose(.forward(current.envelope, message: current.message, account: current.store.account), store: current.store)
    }

    /// mailto: 링크로 새 메일을 연다.
    func compose(mailto url: URL) {
        guard let store else { return showAccountSheet() }
        guard let draft = ComposeDraft.mailto(url, account: store.account) else { return }
        openCompose(draft, store: store)
    }

    func openCompose(_ draft: ComposeDraft, store: MailStore) {
        let controller = ComposeWindowController(store: store, draft: draft)
        controller.onClose = { [weak self, weak controller] in
            self?.composeControllers.removeAll { $0 === controller }
        }
        composeControllers.append(controller)
        controller.showWindow(nil)
    }

    // MARK: - 사서함

    @objc func refreshMailbox(_ sender: Any?) {
        manager.refreshAll()
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let field = searchItem?.searchField else { return }
        window?.makeFirstResponder(field)
    }

    @objc func toggleUnreadOnly(_ sender: Any?) {
        list.toggleUnreadOnly()
    }

    // MARK: - 선택한 메일

    /// 선택한 메일과 그 메일이 든 사서함·스토어
    private var selection: (store: MailStore, mailbox: Mailbox, envelopes: [Envelope])? {
        guard let store, let mailbox = store.selectedMailbox else { return nil }
        let envelopes = list.selectedEnvelopes
        return envelopes.isEmpty ? nil : (store, mailbox, envelopes)
    }

    @objc func deleteMessage(_ sender: Any?) {
        guard let selection else { return }
        // 설정에서 ‘삭제한 메일을 보관함으로’를 골랐으면 보관한다 (이미 보관함·휴지통이면 삭제).
        if Preferences.deleteDestination == .archive, let archive = selection.store.archiveMailbox,
           ![.all, .trash, .junk, .drafts].contains(selection.mailbox.role) {
            return move(selection, to: archive)
        }
        selection.store.delete(selection.envelopes, in: selection.mailbox) { [weak self] error in
            self?.presentFailure("메일을 삭제하지 못했습니다", error)
        }
    }

    @objc func archiveMessage(_ sender: Any?) {
        guard let selection, let archive = selection.store.archiveMailbox else { return }
        move(selection, to: archive)
    }

    @objc func junkMessage(_ sender: Any?) {
        guard let selection, let junk = selection.store.junkMailbox else { return }
        move(selection, to: junk)
    }

    @objc func moveToMailbox(_ sender: NSMenuItem) {
        guard let selection, let path = sender.representedObject as? String,
              let destination = selection.store.mailboxes.first(where: { $0.path == path }) else { return }
        move(selection, to: destination)
    }

    private func move(_ selection: (store: MailStore, mailbox: Mailbox, envelopes: [Envelope]), to destination: Mailbox) {
        selection.store.move(uids: selection.envelopes.map(\.uid), from: selection.mailbox, to: destination) { [weak self] error in
            self?.presentFailure("메일을 옮기지 못했습니다", error)
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
        guard let selection else { return }
        let turnOn = selection.envelopes.contains { !$0.hasFlag(flag) }
        selection.store.setFlag(flag, on: turnOn, envelopes: selection.envelopes, in: selection.mailbox) { [weak self] error in
            self?.presentFailure(failureTitle, error)
        }
    }

    // MARK: - 프린트 / 저장 / 확대

    @objc func printMessage(_ sender: Any?) {
        detail.printMessage()
    }

    /// 원본(.eml)을 파일로 저장한다.
    @objc func saveMessageSource(_ sender: Any?) {
        guard let current = detail.current, let window else { return }
        let panel = NSSavePanel()
        let subject = current.envelope.subject.isEmpty ? "메시지" : current.envelope.subject
        panel.nameFieldStringValue = subject.replacingOccurrences(of: "/", with: "_").prefix(80) + ".eml"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            current.store.fetchRaw(current.envelope, in: current.mailbox) { result in
                do {
                    try result.get().write(to: url, options: .atomic)
                } catch {
                    self?.presentFailure("메시지를 저장하지 못했습니다", error)
                }
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) { detail.zoom(2) }
    @objc func zoomOut(_ sender: Any?) { detail.zoom(0.5) }
    @objc func zoomReset(_ sender: Any?) { detail.zoom(nil) }

    // MARK: - 유효성 (메뉴 + 툴바 공통)

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let targets = list.selectedEnvelopes
        let menuItem = item as? NSMenuItem
        switch item.action {
        case #selector(replyMessage(_:)), #selector(replyAllMessage(_:)), #selector(forwardMessage(_:)),
             #selector(printMessage(_:)), #selector(saveMessageSource(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomReset(_:)):
            return detail.current != nil
        case #selector(toggleRead(_:)):
            // 지금 누르면 일어날 일을 메뉴 제목으로 보여준다.
            menuItem?.title = targets.contains { !$0.isSeen } || targets.isEmpty ? "읽음으로 표시" : "읽지 않음으로 표시"
            return !targets.isEmpty
        case #selector(toggleFlag(_:)):
            menuItem?.title = targets.contains { !$0.isFlagged } || targets.isEmpty ? "깃발 표시" : "깃발 지우기"
            return !targets.isEmpty
        case #selector(deleteMessage(_:)), #selector(moveToMailbox(_:)):
            return !targets.isEmpty
        case #selector(archiveMessage(_:)):
            return !targets.isEmpty && store?.archiveMailbox != nil && store?.selectedMailbox?.role != .all
        case #selector(junkMessage(_:)):
            return !targets.isEmpty && store?.junkMailbox != nil && store?.selectedMailbox?.role != .junk
        case #selector(toggleUnreadOnly(_:)):
            menuItem?.state = list.unreadOnly ? .on : .off
            return store != nil
        case #selector(refreshMailbox(_:)):
            return store != nil
        default:
            return true
        }
    }
}
