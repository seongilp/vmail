import AppKit
import MailCore
import UniformTypeIdentifiers

/// 내보내기 파일의 내용. 비밀번호는 담지 않는다(키체인에만 있다).
struct SettingsBackup: Codable {
    static let currentVersion = 1

    var version = SettingsBackup.currentVersion
    var accounts: [Account]
    var signature: String
    var alwaysLoadRemoteContent: Bool
    var notifyNewMail: Bool
    var autoReply: AutoReplySettings
    var rules: [MailRule]
    /// 글꼴·보기·작성 등 나머지 설정 (이전 버전 파일에는 없다)
    var options: [String: String]?
    var signatures: [Signature]?
}

/// 설정을 JSON 파일로 내보내고 가져온다.
final class SettingsTransfer {
    private let manager: AccountManager
    /// 가져온 계정 중 비밀번호를 입력받아야 하는 것들
    private var pendingAccounts: [Account] = []

    init(manager: AccountManager) {
        self.manager = manager
    }

    func export(from window: NSWindow) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vmail-settings.json"
        panel.allowedContentTypes = [.json]
        panel.message = "계정 정보·규칙·서명 등을 저장합니다. 비밀번호는 포함되지 않습니다."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let backup = SettingsBackup(accounts: self.manager.stores.map(\.account), signature: Preferences.signature,
                                        alwaysLoadRemoteContent: Preferences.alwaysLoadRemoteContent,
                                        notifyNewMail: Preferences.notifyNewMail, autoReply: Preferences.autoReply,
                                        rules: Preferences.rules, options: Preferences.snapshot(),
                                        signatures: Preferences.signatures)
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(backup).write(to: url, options: .atomic)
            } catch {
                self.alert(on: window, "설정을 내보내지 못했습니다", error.localizedDescription)
            }
        }
    }

    func importSettings(into window: NSWindow) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "vmail에서 내보낸 설정 파일을 고르세요."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let backup = try decoder.decode(SettingsBackup.self, from: Data(contentsOf: url))
                guard backup.version <= SettingsBackup.currentVersion else {
                    throw MailError.malformed("더 새로운 버전의 vmail에서 만든 파일입니다.")
                }
                self.apply(backup, window: window)
            } catch {
                self.alert(on: window, "설정을 가져오지 못했습니다", "vmail 설정 파일이 아니거나 손상되었습니다. (\(error.localizedDescription))")
            }
        }
    }

    private func apply(_ backup: SettingsBackup, window: NSWindow) {
        // 서명 목록을 먼저 넣어야 옵션에 든 용도별 지정(서명 ID)이 맞게 연결된다.
        if let signatures = backup.signatures { Preferences.signatures = signatures }
        if let options = backup.options { Preferences.restore(options) }
        Preferences.signature = backup.signature
        Preferences.alwaysLoadRemoteContent = backup.alwaysLoadRemoteContent
        Preferences.notifyNewMail = backup.notifyNewMail
        Preferences.autoReply = backup.autoReply
        Preferences.rules = backup.rules

        // 이미 있는 계정은 건드리지 않고, 없는 계정만 비밀번호를 받아 추가한다.
        let existing = Set(manager.stores.map { $0.account.email.lowercased() })
        pendingAccounts = backup.accounts.filter { !existing.contains($0.email.lowercased()) }
        let summary = "서명·알림·부재중 응답과 규칙 \(backup.rules.count)개를 가져왔습니다."
        if pendingAccounts.isEmpty {
            alert(on: window, "설정을 가져왔습니다", summary)
        } else {
            alert(on: window, "설정을 가져왔습니다",
                  "\(summary)\n새 계정 \(pendingAccounts.count)개는 비밀번호를 입력해야 합니다. 이어서 하나씩 안내합니다.") { [weak self] in
                self?.promptNextAccount(on: window)
            }
        }
    }

    /// 비밀번호가 필요한 계정을 하나씩 계정 시트로 안내한다.
    private func promptNextAccount(on window: NSWindow) {
        guard let account = pendingAccounts.first else { return }
        pendingAccounts = Array(pendingAccounts.dropFirst())
        AccountSheetController.present(on: window, manager: manager, prefill: account) { [weak self] in
            self?.promptNextAccount(on: window)
        }
    }

    private func alert(on window: NSWindow, _ title: String, _ message: String, then: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in then?() }
    }
}
