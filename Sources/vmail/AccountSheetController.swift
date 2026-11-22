import AppKit
import MailCore

/// 계정 추가/수정 시트. 이메일을 입력하면 서버 설정을 자동으로 채운다.
final class AccountSheetController: NSWindowController, NSTextFieldDelegate {
    private let store: MailStore
    private let nameField = NSTextField()
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let usernameField = NSTextField()
    private let imapHostField = NSTextField()
    private let imapPortField = NSTextField()
    private let smtpHostField = NSTextField()
    private let smtpPortField = NSTextField()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton(title: "취소", target: nil, action: nil)
    private let signInButton = NSButton(title: "로그인", target: nil, action: nil)
    private let importButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var importable: [ImportableAccount] = []
    private let appPasswordButton = NSButton(title: "앱 비밀번호 발급 페이지 열기", target: nil, action: nil)

    /// 앱 비밀번호를 발급하는 공식 페이지 (도메인별)
    private static let appPasswordPages: [String: String] = [
        "gmail.com": "https://myaccount.google.com/apppasswords",
        "googlemail.com": "https://myaccount.google.com/apppasswords",
        "icloud.com": "https://account.apple.com/account/manage",
        "me.com": "https://account.apple.com/account/manage",
        "mac.com": "https://account.apple.com/account/manage",
    ]
    /// 사용자가 서버 칸을 직접 고쳤으면 자동 채움을 멈춘다.
    private var serverEdited = false

    private static let hint = "Gmail · 네이버 · iCloud 등은 2단계 인증용 ‘앱 비밀번호’를 입력해야 합니다. 다른 메일 앱에서 쓰던 계정은 ‘키체인에서 가져오기’로 불러올 수 있습니다. 비밀번호는 이 Mac의 키체인에만 저장됩니다."

    init(store: MailStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        buildContent(in: window)
        if let account = store.account {
            fill(account)
            nameField.stringValue = account.displayName
            emailField.stringValue = account.email
            serverEdited = true
        } else {
            nameField.stringValue = NSFullUserName()
        }
        window.initialFirstResponder = emailField
        loadImportableAccounts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    private func buildContent(in window: NSWindow) {
        let title = NSTextField(labelWithString: "메일 계정")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        func hostRow(_ host: NSTextField, _ port: NSTextField) -> NSStackView {
            port.widthAnchor.constraint(equalToConstant: 58).isActive = true
            port.alignment = .right
            let row = NSStackView(views: [host, NSTextField(labelWithString: "포트"), port])
            row.spacing = 6
            return row
        }
        emailField.placeholderString = "name@example.com"
        passwordField.placeholderString = "앱 비밀번호"
        for field in [emailField, usernameField, imapHostField, imapPortField, smtpHostField, smtpPortField] {
            field.delegate = self
        }

        let grid = NSGridView(views: [
            [label("이름"), nameField],
            [label("이메일"), emailField],
            [label("비밀번호"), passwordField],
            [label("사용자 이름"), usernameField],
            [label("받는 서버(IMAP)"), hostRow(imapHostField, imapPortField)],
            [label("보내는 서버(SMTP)"), hostRow(smtpHostField, smtpPortField)],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 3).topPadding = 8

        messageLabel.stringValue = Self.hint
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        signInButton.bezelStyle = .rounded
        signInButton.keyEquivalent = "\r"
        signInButton.target = self
        signInButton.action = #selector(signIn)
        appPasswordButton.bezelStyle = .inline
        appPasswordButton.controlSize = .small
        appPasswordButton.target = self
        appPasswordButton.action = #selector(openAppPasswordPage)
        appPasswordButton.isHidden = true
        let buttons = NSStackView(views: [appPasswordButton, NSView(), spinner, cancelButton, signInButton])
        buttons.spacing = 8

        importButton.bezelStyle = .rounded
        importButton.controlSize = .small
        importButton.addItem(withTitle: "키체인에서 가져오기")
        let header = NSStackView(views: [title, NSView(), importButton])

        let stack = NSStackView(views: [header, grid, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 440),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            // 안내문 길이가 바뀌어도 시트 높이와 행 간격이 흔들리지 않게 높이를 고정한다.
            messageLabel.heightAnchor.constraint(equalToConstant: 44),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)   // 내용에 딱 맞게 — 남는 높이가 그리드 행 사이로 퍼지지 않도록
    }

    private func fill(_ account: Account) {
        usernameField.stringValue = account.username
        imapHostField.stringValue = account.imapHost
        imapPortField.stringValue = "\(account.imapPort)"
        smtpHostField.stringValue = account.smtpHost
        smtpPortField.stringValue = "\(account.smtpPort)"
        updateAppPasswordButton()
    }

    private var appPasswordPage: URL? {
        let domain = emailField.stringValue.components(separatedBy: "@").last?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return Self.appPasswordPages[domain].flatMap(URL.init(string:))
    }

    private func updateAppPasswordButton() {
        appPasswordButton.isHidden = appPasswordPage == nil
    }

    @objc private func openAppPasswordPage() {
        if let url = appPasswordPage { NSWorkspace.shared.open(url) }
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if field === emailField {
            if !serverEdited { fill(Account.preset(email: emailField.stringValue)) }
            updateAppPasswordButton()
        } else {
            serverEdited = true
        }
    }

    // MARK: - 키체인에서 가져오기

    /// Apple Mail 등이 키체인에 저장해 둔 IMAP 계정을 메뉴로 보여준다. 조회는 백그라운드에서.
    private func loadImportableAccounts() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = KeychainImporter.candidates()
            DispatchQueue.main.async { self?.showImportable(found) }
        }
    }

    private func showImportable(_ accounts: [ImportableAccount]) {
        importable = accounts
        guard let menu = importButton.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        if accounts.isEmpty {
            let empty = NSMenuItem(title: "키체인에 저장된 메일 계정이 없습니다", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for (index, account) in accounts.enumerated() {
            let item = NSMenuItem(title: account.title, action: #selector(importAccount(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
    }

    @objc private func importAccount(_ sender: NSMenuItem) {
        guard sender.tag < importable.count else { return }
        let candidate = importable[sender.tag]
        let account = candidate.account
        emailField.stringValue = account.email
        fill(account)
        serverEdited = true
        showMessage("키체인에서 비밀번호를 가져오는 중… macOS가 허용 여부를 물으면 ‘허용’을 누르세요.", isError: false)
        KeychainImporter.password(for: candidate) { [weak self] password in
            guard let self else { return }
            if let password, !password.isEmpty {
                self.passwordField.stringValue = password
                self.showMessage("계정 정보를 가져왔습니다. ‘로그인’을 누르세요.", isError: false)
                self.window?.makeFirstResponder(self.signInButton)
            } else {
                self.showMessage("비밀번호를 가져오지 못했습니다. 직접 입력하세요.", isError: true)
                self.window?.makeFirstResponder(self.passwordField)
            }
        }
    }

    // MARK: - 액션

    /// ESC — 계정이 없는 첫 실행에서도 시트를 닫을 수 있다.
    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    @objc private func cancel() {
        guard cancelButton.isEnabled else { return }   // 로그인 확인 중에는 닫지 않는다
        dismiss()
    }

    @objc private func signIn() {
        guard let account = validatedAccount() else { return }
        let password = passwordField.stringValue
        setBusy(true)
        showMessage("서버에 연결하는 중…", isError: false)
        store.signIn(account: account, password: password) { [weak self] error in
            guard let self else { return }
            self.setBusy(false)
            if let error {
                self.showMessage(error.localizedDescription, isError: true)
            } else {
                self.dismiss()
            }
        }
    }

    /// 입력을 검증해 Account를 만든다. 문제가 있으면 안내하고 nil.
    private func validatedAccount() -> Account? {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        guard MessageBuilder.isValidEmail(email) else { return fail("이메일 주소를 확인하세요.", emailField) }
        guard !passwordField.stringValue.isEmpty else { return fail("비밀번호를 입력하세요.", passwordField) }
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { return fail("사용자 이름을 입력하세요.", usernameField) }
        let imapHost = imapHostField.stringValue.trimmingCharacters(in: .whitespaces)
        let smtpHost = smtpHostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard Self.isValidHost(imapHost) else { return fail("받는 서버 주소를 확인하세요.", imapHostField) }
        guard Self.isValidHost(smtpHost) else { return fail("보내는 서버 주소를 확인하세요.", smtpHostField) }
        guard let imapPort = Self.port(imapPortField.stringValue) else { return fail("IMAP 포트는 1–65535 사이 숫자입니다.", imapPortField) }
        guard let smtpPort = Self.port(smtpPortField.stringValue) else { return fail("SMTP 포트는 1–65535 사이 숫자입니다.", smtpPortField) }
        return Account(displayName: nameField.stringValue.trimmingCharacters(in: .whitespaces), email: email,
                       username: username, imapHost: imapHost, imapPort: imapPort, smtpHost: smtpHost, smtpPort: smtpPort)
    }

    private static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }

    private static func port(_ text: String) -> Int? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return nil }
        return port
    }

    private func fail(_ message: String, _ field: NSTextField) -> Account? {
        showMessage(message, isError: true)
        window?.makeFirstResponder(field)
        return nil
    }

    private func showMessage(_ text: String, isError: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func setBusy(_ busy: Bool) {
        signInButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
