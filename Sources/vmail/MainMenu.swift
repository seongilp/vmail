import AppKit

/// 메뉴바를 코드로 구성한다. 메일 관련 액션은 nil 타깃으로 보내 응답자 체인(창 컨트롤러)이 처리한다.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(mailboxMenu()))
        main.addItem(submenu(messageMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("vmail에 관하여", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("계정 설정…", #selector(AppDelegate.showAccountSettings(_:)), ","))
        menu.addItem(item("로그아웃", #selector(AppDelegate.signOut(_:))))
        menu.addItem(.separator())
        menu.addItem(item("vmail 가리기", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("vmail 종료", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "파일")
        menu.addItem(item("새로운 메일", #selector(MainWindowController.composeMessage(_:)), "n"))
        menu.addItem(.separator())
        menu.addItem(item("닫기", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "편집")
        menu.addItem(item("실행 취소", Selector(("undo:")), "z"))
        menu.addItem(item("실행 복귀", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("오려두기", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("복사하기", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("붙여넣기", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("전체 선택", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("찾기", #selector(MainWindowController.focusSearch(_:)), "f"))
        return menu
    }

    private static func mailboxMenu() -> NSMenu {
        let menu = NSMenu(title: "메일상자")
        menu.addItem(item("새로운 메일 가져오기", #selector(MainWindowController.refreshMailbox(_:)), "r"))
        return menu
    }

    private static func messageMenu() -> NSMenu {
        let menu = NSMenu(title: "메시지")
        menu.addItem(item("답장", #selector(MainWindowController.replyMessage(_:)), "r", [.command, .shift]))
        menu.addItem(item("모두에게 답장", #selector(MainWindowController.replyAllMessage(_:)), "r", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("읽음/읽지 않음으로 표시", #selector(MainWindowController.toggleRead(_:)), "u", [.command, .shift]))
        menu.addItem(item("깃발 표시 전환", #selector(MainWindowController.toggleFlag(_:)), "l", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("보내기", #selector(ComposeWindowController.sendMessage(_:)), "d", [.command, .shift]))
        menu.addItem(item("파일 첨부…", #selector(ComposeWindowController.attachFiles(_:)), "a", [.command, .shift]))
        menu.addItem(.separator())
        let delete = item("삭제", #selector(MainWindowController.deleteMessage(_:)), "\u{8}")
        menu.addItem(delete)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "윈도우")
        menu.addItem(item("최소화", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("확대/축소", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("메일 뷰어", #selector(MainWindowController.showMainWindow(_:)), "0"))
        return menu
    }
}
