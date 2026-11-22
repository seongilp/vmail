import Foundation
import MailCore

/// 이동·검색·임시 저장·폴더 관리 등 부가 동작
extension MailStore {
    static let searchLimit = 200

    var draftsMailbox: Mailbox? { mailboxes.first { $0.role == .drafts } }
    var junkMailbox: Mailbox? { mailboxes.first { $0.role == .junk } }
    var archiveMailbox: Mailbox? { mailboxes.first { $0.role == .all } }
    var inboxMailbox: Mailbox? { mailboxes.first { $0.role == .inbox } }

    /// 지금까지 본 메일에서 모은 주소 (받는 사람 자동 완성용)
    var knownAddresses: [Address] {
        var seen = Set<String>()
        var result: [Address] = []
        for state in states.values {
            for envelope in state.envelopes {
                for address in envelope.from + envelope.to + envelope.cc where seen.insert(address.email.lowercased()).inserted {
                    result.append(address)
                }
            }
        }
        return result
    }

    /// 받은편지함을 새로 고쳤을 때 이전보다 UID가 큰 읽지 않은 메일을 알린다.
    func notifyNewMail(in mailbox: Mailbox, fresh: [Envelope]) {
        let old = state(for: mailbox)
        guard mailbox.role == .inbox, old.hasLoaded else { return }
        let lastKnown = old.envelopes.first?.uid ?? 0
        NewMailNotifier.notify(fresh.filter { $0.uid > lastKnown && !$0.isSeen })
    }

    // MARK: - 이동 / 완전 삭제

    func move(uids: [UInt32], from source: Mailbox, to destination: Mailbox, failure: @escaping (Error) -> Void) {
        guard source != destination else { return }
        remove(uids: uids, from: source, failure: failure) { client in
            try client.move(uids: uids, to: destination.path)
        }
    }

    /// 휴지통을 거치지 않고 완전히 삭제한다 (교체된 임시 저장본 정리 등).
    func expunge(uids: [UInt32], in mailbox: Mailbox, failure: @escaping (Error) -> Void) {
        remove(uids: uids, from: mailbox, failure: failure) { client in
            try client.deletePermanently(uids: uids)
        }
    }

    private func remove(uids: [UInt32], from mailbox: Mailbox, failure: @escaping (Error) -> Void,
                        work: @escaping (IMAPClient) throws -> Void) {
        guard let session, !uids.isEmpty else { return }
        let targets = Set(uids)
        update(mailbox, mutation: .removed(targets)) { state in
            let before = state.envelopes.count
            state.envelopes = state.envelopes.filter { !targets.contains($0.uid) }
            state.exists = max(0, state.exists - (before - state.envelopes.count))
        }
        let path = mailbox.path
        session.perform({ client in
            try client.ensureSelected(path)
            try work(client)
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .failure(let error) = result { failure(error) }
            self.reload(mailbox)
            self.refreshUnread()
        }
    }

    // MARK: - 검색 / 원문

    /// 서버에서 사서함 전체를 검색한다. 최신 searchLimit 건까지.
    func search(_ text: String, in mailbox: Mailbox, completion: @escaping (Result<[Envelope], Error>) -> Void) {
        guard let session else { return }
        let path = mailbox.path
        session.perform({ client -> [Envelope] in
            try client.ensureSelected(path)
            let uids = try client.search(text: text)
            return try client.fetchEnvelopes(uids: Array(uids.prefix(Self.searchLimit)))
        }) { [weak self] result in
            guard let self, self.session === session else { return }
            completion(result)
        }
    }

    func fetchRaw(_ envelope: Envelope, in mailbox: Mailbox, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let session else { return }
        let path = mailbox.path
        session.perform({ client -> Data in
            try client.ensureSelected(path)
            return try client.fetchBody(uid: envelope.uid)
        }, completion: completion)
    }

    // MARK: - 임시 저장

    func saveDraft(_ message: OutgoingMessage, completion: @escaping (Error?) -> Void) {
        guard let session, let drafts = draftsMailbox else {
            completion(MailError.server("이 계정에는 임시보관함이 없습니다."))
            return
        }
        session.saveDraft(message, to: drafts) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .failure(let error) = result {
                completion(error)
            } else {
                completion(nil)
                if self.selectedMailbox == drafts { self.reload(drafts) }
            }
        }
    }

    // MARK: - 폴더 관리

    /// 이름을 검증해 서버 경로를 만든다. 구분자가 들어간 이름은 받지 않는다.
    private func folderPath(named name: String, under parentPath: String?, delimiter: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw MailError.server("폴더 이름을 입력하세요.") }
        guard !trimmed.contains(delimiter) else { throw MailError.server("폴더 이름에 ‘\(delimiter)’ 문자는 쓸 수 없습니다.") }
        let leaf = ModifiedUTF7.encode(trimmed)
        return parentPath.map { $0 + delimiter + leaf } ?? leaf
    }

    private var defaultDelimiter: String {
        mailboxes.compactMap(\.delimiter).first { !$0.isEmpty } ?? "/"
    }

    func createFolder(named name: String, under parent: Mailbox?, completion: @escaping (Error?) -> Void) {
        runFolderChange(completion) { [self] in
            let path = try folderPath(named: name, under: parent?.path, delimiter: parent?.delimiter ?? defaultDelimiter)
            return { try $0.createMailbox(path) }
        }
    }

    func renameFolder(_ mailbox: Mailbox, to name: String, completion: @escaping (Error?) -> Void) {
        runFolderChange(completion) { [self] in
            let delimiter = mailbox.delimiter ?? defaultDelimiter
            let parents = mailbox.path.components(separatedBy: delimiter).dropLast()
            let parentPath = parents.isEmpty ? nil : parents.joined(separator: delimiter)
            let path = try folderPath(named: name, under: parentPath, delimiter: delimiter)
            return { try $0.renameMailbox(mailbox.path, to: path) }
        }
    }

    func deleteFolder(_ mailbox: Mailbox, completion: @escaping (Error?) -> Void) {
        if selectedMailbox == mailbox, let inbox = inboxMailbox { select(inbox) }
        runFolderChange(completion) { { try $0.deleteMailbox(mailbox.path) } }
    }

    private func runFolderChange(_ completion: @escaping (Error?) -> Void,
                                 _ prepare: () throws -> (IMAPClient) throws -> Void) {
        guard let session else { return }
        let work: (IMAPClient) throws -> Void
        do {
            work = try prepare()
        } catch {
            completion(error)
            return
        }
        session.perform(work) { [weak self] result in
            guard let self, self.session === session else { return }
            if case .failure(let error) = result {
                completion(error)
            } else {
                completion(nil)
                self.loadMailboxes()
            }
        }
    }
}
