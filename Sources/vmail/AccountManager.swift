import Foundation
import MailCore

/// 여러 계정의 스토어를 관리한다. 화면은 current(선택된 사서함이 속한 계정)를 보여준다.
final class AccountManager {
    static let accountsDidChange = Notification.Name("AccountManager.accountsDidChange")
    static let currentDidChange = Notification.Name("AccountManager.currentDidChange")

    private static let accountsKey = "accounts"
    private static let legacyAccountKey = "account"   // 단일 계정 시절의 저장 형식

    private(set) var stores: [MailStore] = []
    private(set) var current: MailStore?

    var totalUnread: Int { stores.reduce(0) { $0 + $1.inboxUnread } }

    /// 저장된 계정을 읽어 연결한다. 키체인에 비밀번호가 없는 계정은 건너뛴다.
    func start() {
        for account in savedAccounts() {
            guard let password = Keychain.password(account: account.email) else {
                NSLog("vmail: \(account.email) 의 비밀번호가 키체인에 없어 건너뜁니다.")
                continue
            }
            stores.append(MailStore(account: account, password: password))
        }
        current = stores.first
        post(Self.accountsDidChange)
        post(Self.currentDidChange)
    }

    /// 로그인을 검증한 뒤 계정을 추가한다. 같은 이메일(또는 replacing)이 있으면 그 자리를 교체한다.
    func add(_ account: Account, password: String, replacing: MailStore? = nil, completion: @escaping (Error?) -> Void) {
        MailSession.verify(account: account, password: password) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                completion(error)
                return
            }
            Keychain.save(password: password, account: account.email)
            let fresh = MailStore(account: account, password: password)
            let old = replacing ?? self.stores.first { $0.account.email.lowercased() == account.email.lowercased() }
            if let old, let index = self.stores.firstIndex(where: { $0 === old }) {
                if old.account.email != account.email { Keychain.delete(account: old.account.email) }
                old.shutdown(removeData: old.account.email != account.email)
                self.stores = self.stores.enumerated().map { $0.offset == index ? fresh : $0.element }
            } else {
                self.stores = self.stores + [fresh]
            }
            self.current = fresh
            self.persist()
            self.post(Self.accountsDidChange)
            self.post(Self.currentDidChange)
            completion(nil)
        }
    }

    /// 계정을 제거한다. 이 Mac의 비밀번호와 캐시만 지우고 서버의 메일은 그대로 둔다.
    func remove(_ store: MailStore) {
        Keychain.delete(account: store.account.email)
        store.shutdown(removeData: true)
        stores = stores.filter { $0 !== store }
        if current === store { current = stores.first }
        persist()
        post(Self.accountsDidChange)
        post(Self.currentDidChange)
    }

    /// 사서함을 고른다. 다른 계정의 사서함이면 current도 바꾼다.
    func select(_ mailbox: Mailbox, in store: MailStore) {
        let switching = current !== store
        current = store
        store.open(mailbox)
        if switching { post(Self.currentDidChange) }
    }

    func refreshAll() {
        for store in stores {
            store.loadMailboxes()
            store.refresh()
        }
    }

    // MARK: - Private

    private func savedAccounts() -> [Account] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.accountsKey) {
            do {
                return try JSONDecoder().decode([Account].self, from: data)
            } catch {
                NSLog("vmail: 계정 목록 해석 실패 — \(error.localizedDescription)")
                return []
            }
        }
        if let data = defaults.data(forKey: Self.legacyAccountKey),
           let account = try? JSONDecoder().decode(Account.self, from: data) {
            return [account]
        }
        return []
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(stores.map(\.account))
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyAccountKey)
        } catch {
            NSLog("vmail: 계정 목록 저장 실패 — \(error.localizedDescription)")
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }
}
