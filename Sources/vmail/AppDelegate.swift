import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = AccountManager()
    private lazy var mailboxMenu = MailboxMenu(manager: manager)
    private var mainWindowController: MainWindowController?
    private var settingsController: SettingsWindowController?
    private lazy var transfer = SettingsTransfer(manager: manager)
    /// 창이 준비되기 전에 들어온 mailto: 링크
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(mailboxMenu: mailboxMenu)
        manager.start()
        let controller = MainWindowController(manager: manager, mailboxMenu: mailboxMenu)
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(self, selector: #selector(unreadChanged),
                                               name: MailStore.unreadDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(unreadChanged),
                                               name: AccountManager.accountsDidChange, object: manager)
        if manager.stores.isEmpty {
            controller.showAccountSheet()
        } else if Preferences.notifyNewMail {
            NewMailNotifier.requestAuthorization()
        }
        pendingURLs.forEach(controller.compose(mailto:))
        pendingURLs = []
    }

    /// mailto: 링크를 눌렀을 때
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller = mainWindowController else {
            pendingURLs += urls
            return
        }
        urls.forEach(controller.compose(mailto:))
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
        let total = manager.totalUnread
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    // MARK: - 메뉴 액션

    @objc func showSettings(_ sender: Any?) {
        settings.show(accounts: false)
    }

    @objc func showAccounts(_ sender: Any?) {
        settings.show(accounts: true)
    }

    @objc func addAccount(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        mainWindowController?.showAccountSheet()
    }

    @objc func exportSettings(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? mainWindowController?.window else { return }
        transfer.export(from: window)
    }

    @objc func importSettings(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? mainWindowController?.window else { return }
        transfer.importSettings(into: window)
    }

    private var settings: SettingsWindowController {
        if let settingsController { return settingsController }
        let controller = SettingsWindowController(manager: manager)
        settingsController = controller
        return controller
    }
}
