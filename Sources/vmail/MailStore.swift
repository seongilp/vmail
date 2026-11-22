import AppKit
import MailCore

/// 사서함 하나의 목록 상태. 사서함별로 따로 보관해 전환 시 서로 섞이지 않게 한다.
struct MailboxListState {
    var envelopes: [Envelope] = []
    var exists = 0
    var isLoading = false
    var hasLoaded = false
    var error: String?

    var canLoadMore: Bool { hasLoaded && envelopes.count < exists }
}

/// 앱의 모델. 메인 스레드에서만 접근하고, 네트워크는 MailSession의 백그라운드 큐가 맡는다.
final class MailStore {
    static let accountDidChange = Notification.Name("MailStore.accountDidChange")
    static let mailboxesDidChange = Notification.Name("MailStore.mailboxesDidChange")
    static let messagesDidChange = Notification.Name("MailStore.messagesDidChange")   // userInfo["path"]
    static let selectionDidChange = Notification.Name("MailStore.selectionDidChange")
    static let unreadDidChange = Notification.Name("MailStore.unreadDidChange")

    static let pageSize = 50
    private static let refreshInterval: TimeInterval = 60
    private static let accountKey = "account"

    private(set) var account: Account?
    private(set) var mailboxes: [Mailbox] = []
    private(set) var selectedMailbox: Mailbox?
    private(set) var inboxUnread = 0
    private(set) var mailboxError: String?

    private var session: MailSession?
    private var cache: DiskCache?
    private var states: [String: MailboxListState] = [:]
    private let bodies = NSCache<NSString, MessageBox>()
    private var refreshTimer: Timer?

    private final class MessageBox {
        let message: ParsedMessage
        init(_ message: ParsedMessage) { self.message = message }
    }

    // MARK: - 계정

    func start() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountKey),
              let account = try? JSONDecoder().decode(Account.self, from: data),
              let password = Keychain.password(account: account.email) else { return }
        activate(account: account, password: password)
    }

    /// 로그인 검증 후 계정을 저장하고 연결한다.
    func signIn(account: Account, password: String, completion: @escaping (Error?) -> Void) {
        MailSession.verify(account: account, password: password) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(error)
            case .success:
                if let data = try? JSONEncoder().encode(account) {
                    UserDefaults.standard.set(data, forKey: Self.accountKey)
                }
                Keychain.save(password: password, account: account.email)
                self.deactivate()
                self.activate(account: account, password: password)
                completion(nil)
            }
        }
    }

    func signOut() {
        if let account { Keychain.delete(account: account.email) }
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        cache?.removeAll()
        deactivate()
        post(Self.accountDidChange)
        post(Self.mailboxesDidChange)
        post(Self.selectionDidChange)
    }

    private func activate(account: Account, password: String) {
        self.account = account
        session = MailSession(account: account, password: password)
        let cache = DiskCache(email: account.email)
        self.cache = cache
        mailboxes = Self.sorted(cache.loadMailboxes())
        post(Self.accountDidChange)
        post(Self.mailboxesDidChange)
        if let inbox = mailboxes.first(where: { $0.role == .inbox }) { select(inbox) }
        loadMailboxes()

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        session?.disconnect()
        session = nil
        cache = nil
        account = nil
        mailboxes = []
        selectedMailbox = nil
        states = [:]
        mailboxError = nil
        bodies.removeAllObjects()
        inboxUnread = 0
        post(Self.unreadDidChange)
    }

    // MARK: - 사서함

    func loadMailboxes() {
        guard let session else { return }
        session.perform({ try $0.listMailboxes() }) { [weak self] result in
            guard let self, self.session === session else { return }
            switch result {
            case .success(let list):
                self.mailboxError = nil
                self.mailboxes = Self.sorted(list)
                self.cache?.saveMailboxes(self.mailboxes)
                self.post(Self.mailboxesDidChange)
                if self.selectedMailbox == nil, let inbox = self.mailboxes.first(where: { $0.role == .inbox }) ?? self.mailboxes.first {
                    self.select(inbox)
                }
            case .failure(let error):
                self.mailboxError = error.localizedDescription
                self.post(Self.mailboxesDidChange)
            }
        }
    }

    func select(_ mailbox: Mailbox) {
        guard mailbox != selectedMailbox else { return }
        selectedMailbox = mailbox
        if states[mailbox.path] == nil {
            states[mailbox.path] = MailboxListState(envelopes: cache?.loadEnvelopes(path: mailbox.path) ?? [])
        }
        post(Self.selectionDidChange)
        refresh()
    }

    func state(for mailbox: Mailbox) -> MailboxListState {
        states[mailbox.path] ?? MailboxListState()
    }

    var trashMailbox: Mailbox? { mailboxes.first { $0.role == .trash } }
    var sentMailbox: Mailbox? { mailboxes.first { $0.role == .sent } }

    // MARK: - 메시지 목록

    /// 선택된 사서함을 새로 고친다. 지금까지 불러온 개수만큼(최소 한 페이지) 다시 가져온다.
    func refresh() {
        guard let mailbox = selectedMailbox else {
            if account != nil, mailboxes.isEmpty { loadMailboxes() }
            return
        }
        load(mailbox, count: max(Self.pageSize, state(for: mailbox).envelopes.count))
        refreshUnread()
    }

    func loadMore() {
        guard let mailbox = selectedMailbox, state(for: mailbox).canLoadMore else { return }
        load(mailbox, count: state(for: mailbox).envelopes.count + Self.pageSize)
    }

    private func load(_ mailbox: Mailbox, count: Int) {
        guard let session, !state(for: mailbox).isLoading else { return }
        update(mailbox) { $0.isLoading = true }
        let path = mailbox.path
        session.perform({ client -> (MailboxStatus, [Envelope]) in
            let status = try client.select(path)
            guard status.exists > 0 else { return (status, []) }
            let lower = max(1, status.exists - count + 1)
            return (status, try client.fetchEnvelopes(lower...status.exists))
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            switch result {
            case .success(let (status, envelopes)):
                self.update(mailbox) {
                    $0.envelopes = envelopes
                    $0.exists = status.exists
                    $0.isLoading = false
                    $0.hasLoaded = true
                    $0.error = nil
                }
                self.cache?.saveEnvelopes(Array(envelopes.prefix(Self.pageSize)), path: path)
            case .failure(let error):
                self.update(mailbox) {
                    $0.isLoading = false
                    $0.error = error.localizedDescription
                }
            }
        }
    }

    private func refreshUnread() {
        guard let session, let inbox = mailboxes.first(where: { $0.role == .inbox }) else { return }
        session.perform({ try $0.unseenCount(inbox.path) }) { [weak self] result in
            guard let self, self.session === session, case .success(let count) = result else { return }
            self.inboxUnread = count
            self.post(Self.unreadDidChange)
        }
    }

    /// 상태를 복사해 고친 뒤 통째로 교체하고 알린다.
    private func update(_ mailbox: Mailbox, _ change: (inout MailboxListState) -> Void) {
        var next = state(for: mailbox)
        change(&next)
        states[mailbox.path] = next
        NotificationCenter.default.post(name: Self.messagesDidChange, object: self, userInfo: ["path": mailbox.path])
    }

    // MARK: - 본문

    func loadBody(_ envelope: Envelope, in mailbox: Mailbox, completion: @escaping (Result<ParsedMessage, Error>) -> Void) {
        let key = "\(mailbox.path)#\(envelope.uid)" as NSString
        if let cached = bodies.object(forKey: key) {
            completion(.success(cached.message))
            return
        }
        guard let session else { return }
        let path = mailbox.path
        session.perform({ client -> ParsedMessage in
            try client.ensureSelected(path)
            return ParsedMessage.parse(try client.fetchBody(uid: envelope.uid))   // MIME 해석도 백그라운드에서
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .success(let message) = result { self.bodies.setObject(MessageBox(message), forKey: key) }
            completion(result)
        }
    }

    // MARK: - 플래그 / 삭제

    func setFlag(_ flag: String, on: Bool, envelopes: [Envelope], in mailbox: Mailbox,
                 failure: @escaping (Error) -> Void) {
        let uids = envelopes.filter { $0.hasFlag(flag) != on }.map(\.uid)
        guard let session, !uids.isEmpty else { return }
        let targets = Set(uids)
        update(mailbox) { state in
            state.envelopes = state.envelopes.map { targets.contains($0.uid) ? $0.settingFlag(flag, on) : $0 }
        }
        let path = mailbox.path
        session.perform({ client in
            try client.ensureSelected(path)
            try client.store(uids: uids, flag: flag, add: on)
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .failure(let error) = result {
                failure(error)
                self.load(mailbox, count: max(Self.pageSize, self.state(for: mailbox).envelopes.count))
            } else if flag == "\\Seen" {
                self.refreshUnread()
            }
        }
    }

    /// 휴지통으로 옮긴다. 이미 휴지통이거나 휴지통이 없으면 완전히 삭제한다.
    func delete(_ envelopes: [Envelope], in mailbox: Mailbox, failure: @escaping (Error) -> Void) {
        let uids = envelopes.map(\.uid)
        guard let session, !uids.isEmpty else { return }
        let targets = Set(uids)
        update(mailbox) { state in
            state.envelopes = state.envelopes.filter { !targets.contains($0.uid) }
            state.exists = max(0, state.exists - uids.count)
        }
        let path = mailbox.path
        let trashPath = mailbox.role == .trash ? nil : trashMailbox?.path
        session.perform({ client in
            try client.ensureSelected(path)
            if let trashPath {
                try client.move(uids: uids, to: trashPath)
            } else {
                try client.deletePermanently(uids: uids)
            }
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .failure(let error) = result {
                failure(error)
                self.load(mailbox, count: max(Self.pageSize, self.state(for: mailbox).envelopes.count + uids.count))
            } else {
                self.refreshUnread()
            }
        }
    }

    /// 사서함의 모든 메일을 읽음으로 표시한다.
    func markAllRead(in mailbox: Mailbox, failure: @escaping (Error) -> Void) {
        guard let session else { return }
        update(mailbox) { state in
            state.envelopes = state.envelopes.map { $0.settingFlag("\\Seen", true) }
        }
        let path = mailbox.path
        session.perform({ client in
            guard try client.select(path).exists > 0 else { return }
            try client.storeAll(flag: "\\Seen")
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .failure(let error) = result { failure(error) }
            self.reload(mailbox)
            self.refreshUnread()
        }
    }

    /// 사서함의 모든 메일을 완전히 삭제한다. (휴지통·스팸 비우기)
    func empty(_ mailbox: Mailbox, failure: @escaping (Error) -> Void) {
        guard let session else { return }
        update(mailbox) { state in
            state.envelopes = []
            state.exists = 0
        }
        let path = mailbox.path
        session.perform({ client in
            guard try client.select(path).exists > 0 else { return }
            try client.expungeAll()
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .failure(let error) = result { failure(error) }
            self.reload(mailbox)
        }
    }

    /// 특정 사서함을 열고 새로 가져온다.
    func open(_ mailbox: Mailbox) {
        if selectedMailbox == mailbox { refresh() } else { select(mailbox) }
    }

    private func reload(_ mailbox: Mailbox) {
        load(mailbox, count: max(Self.pageSize, state(for: mailbox).envelopes.count))
    }

    // MARK: - 보내기

    func send(_ message: OutgoingMessage, completion: @escaping (Error?) -> Void) {
        guard let session else {
            completion(MailError.connection("계정이 설정되지 않았습니다."))
            return
        }
        session.send(message, sentMailbox: sentMailbox) { result in
            if case .failure(let error) = result {
                completion(error)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - 도우미

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }

    private static func sorted(_ mailboxes: [Mailbox]) -> [Mailbox] {
        let order = MailboxRole.allCases
        return mailboxes.sorted { a, b in
            let ia = order.firstIndex(of: a.role) ?? order.count
            let ib = order.firstIndex(of: b.role) ?? order.count
            if ia != ib { return ia < ib }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
