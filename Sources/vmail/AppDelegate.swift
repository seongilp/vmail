import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MailStore()
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        let controller = MainWindowController(store: store)
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(self, selector: #selector(unreadChanged),
                                               name: MailStore.unreadDidChange, object: store)
        store.start()
        if store.account == nil { controller.showAccountSheet() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc private func unreadChanged() {
        NSApp.dockTile.badgeLabel = store.inboxUnread > 0 ? "\(store.inboxUnread)" : nil
    }

    @objc func showAccountSettings(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        mainWindowController?.showAccountSheet()
    }

    @objc func signOut(_ sender: Any?) {
        guard let window = mainWindowController?.window, let account = store.account else { return }
        let alert = NSAlert()
        alert.messageText = "\(account.email) 계정에서 로그아웃할까요?"
        alert.informativeText = "이 Mac에 저장된 비밀번호와 캐시가 삭제됩니다. 서버의 메일은 그대로 남습니다."
        alert.addButton(withTitle: "로그아웃")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.signOut()
            self?.mainWindowController?.showAccountSheet()
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(signOut(_:)) { return store.account != nil }
        return true
    }
}
