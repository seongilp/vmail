import Foundation

/// 계정 하나의 IMAP 연결을 직렬 큐에서 관리한다. 모든 완료 핸들러는 메인 큐에서 호출된다.
public final class MailSession {
    public let account: Account
    private let password: String
    private let imapQueue = DispatchQueue(label: "com.zihado.vmail.imap", qos: .userInitiated)
    private let smtpQueue = DispatchQueue(label: "com.zihado.vmail.smtp", qos: .userInitiated)
    private var client: IMAPClient?   // imapQueue 에서만 접근

    public init(account: Account, password: String) {
        self.account = account
        self.password = password
    }

    /// IMAP 작업을 백그라운드에서 실행한다. 연결이 끊겨 있으면 다시 붙고, 연결 오류면 한 번 재시도한다.
    public func perform<T>(_ work: @escaping (IMAPClient) throws -> T,
                           completion: @escaping (Result<T, Error>) -> Void) {
        imapQueue.async { [self] in
            let result: Result<T, Error>
            do {
                result = .success(try runWithRetry(work))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func send(_ message: OutgoingMessage, sentMailbox: Mailbox?,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        let account = self.account
        let password = self.password
        smtpQueue.async { [self] in
            do {
                let data = MessageBuilder.build(message)
                let smtp = SMTPClient(host: account.smtpHost, port: account.smtpPort, security: account.smtpSecurity)
                try smtp.send(username: account.username, password: password, from: account.email,
                              recipients: (message.to + message.cc).map(\.email), message: data)
                if let sentMailbox, !account.serverSavesSentMail {
                    // 보낸편지함 저장 실패는 발송 성공을 뒤집지 않는다.
                    perform({ try $0.append(to: sentMailbox.path, message: data) }, completion: { _ in })
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    public func disconnect() {
        imapQueue.async { [self] in
            client?.logout()
            client = nil
        }
    }

    /// 계정 설정이 맞는지 로그인만 해 본다.
    public static func verify(account: Account, password: String,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let client = IMAPClient(host: account.imapHost, port: account.imapPort, security: account.imapSecurity)
            do {
                try client.connect()
                try client.login(user: account.username, password: password)
                client.logout()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                client.close()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Private (imapQueue)

    private func runWithRetry<T>(_ work: (IMAPClient) throws -> T) throws -> T {
        do {
            return try work(try connectedClient())
        } catch let error as MailError where error.isConnectionFailure {
            client?.close()
            client = nil
            return try work(try connectedClient())
        }
    }

    private func connectedClient() throws -> IMAPClient {
        if let client { return client }
        let fresh = IMAPClient(host: account.imapHost, port: account.imapPort, security: account.imapSecurity)
        do {
            try fresh.connect()
            try fresh.login(user: account.username, password: password)
        } catch {
            fresh.close()
            throw error
        }
        client = fresh
        return fresh
    }
}
