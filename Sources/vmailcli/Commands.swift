import Foundation
import MailCore
import Security

struct CLIError: LocalizedError {
    let message: String
    /// 인자를 잘못 준 경우(종료 코드 64)인지, 실행 중 오류(종료 코드 1)인지
    var isUsage = false
    var errorDescription: String? { message }
}

/// 명령별 동작. IMAP/SMTP는 동기 호출이라 그대로 순서대로 실행한다.
struct Commands {
    private static let appDomain = "com.zihado.vmail"
    private static let defaultCount = 20
    private static let maxCount = 500

    let options: CommandLineOptions

    func run(_ command: String) throws {
        switch command {
        case "accounts": try accounts()
        case "mailboxes": try mailboxes()
        case "list": try list()
        case "read": try read()
        case "search": try search()
        case "send": try send()
        case "mark": try mark()
        case "move": try move()
        case "delete": try delete()
        case "doctor": try doctor()
        case "agent-guide": print(AgentGuide.text)
        case "install-skill": try installSkill()
        default: throw CLIError(message: "알 수 없는 명령입니다: \(command)\n‘vmail --help’로 사용법을 확인하세요.", isUsage: true)
        }
    }

    // MARK: - 계정

    /// 앱이 저장한 계정 목록, 또는 --config 로 지정한 설정 파일의 계정
    private func loadAccounts() throws -> [Account] {
        struct Backup: Decodable { let accounts: [Account] }
        if let path = options.value("--config") {
            do {
                return try JSONDecoder().decode(Backup.self, from: Data(contentsOf: URL(fileURLWithPath: path))).accounts
            } catch {
                throw CLIError(message: "설정 파일을 읽지 못했습니다: \(path) (\(error.localizedDescription))")
            }
        }
        guard let data = UserDefaults(suiteName: Self.appDomain)?.data(forKey: "accounts") else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    private func selectedAccount() throws -> Account {
        let accounts = try loadAccounts()
        guard !accounts.isEmpty else {
            throw CLIError(message: "등록된 계정이 없습니다. vmail 앱에서 계정을 먼저 추가하세요.")
        }
        guard let query = options.value("--account")?.lowercased() else { return accounts[0] }
        let matches = accounts.filter { $0.email.lowercased().contains(query) }
        guard matches.count == 1 else {
            let list = accounts.map(\.email).joined(separator: ", ")
            throw CLIError(message: matches.isEmpty ? "‘\(query)’에 맞는 계정이 없습니다. (등록된 계정: \(list))"
                                                    : "‘\(query)’에 맞는 계정이 여러 개입니다: \(matches.map(\.email).joined(separator: ", "))")
        }
        return matches[0]
    }

    /// 비밀번호: VMAIL_PASSWORD 환경 변수가 있으면 그것을, 없으면 앱이 키체인에 저장한 것을 쓴다.
    private func password(for account: Account) throws -> String {
        if let env = ProcessInfo.processInfo.environment["VMAIL_PASSWORD"], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.appDomain,
            kSecAttrAccount as String: account.email, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "키체인에서 \(account.email)의 비밀번호를 읽지 못했습니다 (\(status)). "
                + "허용 창이 뜨면 ‘항상 허용’을 누르거나, VMAIL_PASSWORD 환경 변수로 지정하세요.")
        }
        return password
    }

    private func connect(_ account: Account) throws -> IMAPClient {
        let client = IMAPClient(host: account.imapHost, port: account.imapPort, security: account.imapSecurity)
        try client.connect()
        try client.login(user: account.username, password: try password(for: account))
        return client
    }

    /// 이름·경로·역할로 사서함을 찾는다. 지정하지 않으면 받은편지함.
    private func mailbox(in client: IMAPClient) throws -> Mailbox {
        let all = try client.listMailboxes()
        let query = options.value("--mailbox")?.lowercased() ?? "inbox"
        if let role = MailboxRole(rawValue: query), let match = all.first(where: { $0.role == role }) { return match }
        if let match = all.first(where: { $0.path.lowercased() == query || $0.name.lowercased() == query }) { return match }
        if let match = all.first(where: { $0.leafName.lowercased() == query }) { return match }
        throw CLIError(message: "사서함 ‘\(query)’을(를) 찾을 수 없습니다. ‘vmail mailboxes’로 목록을 확인하세요.")
    }

    private var count: Int {
        guard let text = options.value("--count") else { return Self.defaultCount }
        guard let value = Int(text), value > 0 else { fail("개수(-n)는 1 이상의 숫자여야 합니다: \(text)", code: 64) }
        return min(value, Self.maxCount)
    }

    // MARK: - 명령

    private func accounts() throws {
        let accounts = try loadAccounts()
        if options.has("--json") { return printJSON(accounts) }
        if accounts.isEmpty { print("등록된 계정이 없습니다. vmail 앱에서 계정을 먼저 추가하세요.") }
        for account in accounts {
            print("\(account.email)\t\(account.imapHost):\(account.imapPort)\t\(account.smtpHost):\(account.smtpPort)")
        }
    }

    private func mailboxes() throws {
        let client = try connect(try selectedAccount())
        defer { client.logout() }
        let all = try client.listMailboxes()
        if options.has("--json") { return printJSON(all) }
        for mailbox in all {
            print("\(mailbox.role == .other ? "-" : mailbox.role.rawValue)\t\(mailbox.name)")
        }
    }

    private func list() throws {
        let client = try connect(try selectedAccount())
        defer { client.logout() }
        let status = try client.select(try mailbox(in: client).path)
        guard status.exists > 0 else { return printEnvelopes([]) }
        // 읽지 않은 것만 볼 때는 넉넉히 가져와 거른다.
        let window = options.has("--unread") ? min(status.exists, max(count * 5, 100)) : min(status.exists, count)
        var envelopes = try client.fetchEnvelopes((status.exists - window + 1)...status.exists)
        if options.has("--unread") { envelopes = envelopes.filter { !$0.isSeen } }
        printEnvelopes(Array(envelopes.prefix(count)))
    }

    private func search() throws {
        guard let text = options.positionals.first, !text.isEmpty else {
            throw CLIError(message: "검색어를 입력하세요. 예: vmail search \"회의\"", isUsage: true)
        }
        let client = try connect(try selectedAccount())
        defer { client.logout() }
        try client.select(try mailbox(in: client).path)
        let uids = try client.search(text: text, field: options.has("--from") ? .from : .text)
        printEnvelopes(try client.fetchEnvelopes(uids: Array(uids.prefix(count))))
    }

    private func read() throws {
        guard let text = options.positionals.first, let uid = UInt32(text) else {
            throw CLIError(message: "읽을 메일의 UID를 입력하세요. ‘vmail list’의 첫 열이 UID입니다.", isUsage: true)
        }
        let client = try connect(try selectedAccount())
        defer { client.logout() }
        try client.select(try mailbox(in: client).path)
        let raw = try client.fetchBody(uid: uid)
        if options.has("--raw") {
            FileHandle.standardOutput.write(raw)
            return
        }
        let message = ParsedMessage.parse(raw)
        if let directory = options.value("--attachments") { try save(message.attachments, to: directory) }
        if options.has("--json") {
            return printJSON(MessageOutput(uid: uid, subject: message.subject, from: message.from, to: message.to, cc: message.cc,
                                           date: message.date, body: message.plainText,
                                           attachments: message.attachments.map { .init(filename: $0.filename, mimeType: $0.mimeType, size: $0.data.count) }))
        }
        print("제목: \(message.subject)\n보낸 사람: \(message.from)\n받는 사람: \(message.to)")
        if !message.cc.isEmpty { print("참조: \(message.cc)") }
        if let date = message.date { print("날짜: \(Self.dateFormatter.string(from: date))") }
        for attachment in message.attachments {
            print("첨부: \(attachment.filename) (\(ByteCountFormatter().string(fromByteCount: Int64(attachment.data.count))))")
        }
        print("\n\(message.plainText)")
    }

    private func send() throws {
        let account = try selectedAccount()
        func addresses(_ name: String) throws -> [Address] {
            guard let list = MessageBuilder.parseAddressList(options.all(name).joined(separator: ",")) else {
                throw CLIError(message: "\(name) 주소가 올바르지 않습니다: \(options.all(name).joined(separator: ", "))", isUsage: true)
            }
            return list
        }
        let to = try addresses("--to")
        let cc = try addresses("--cc")
        let bcc = try addresses("--bcc")
        guard !(to + cc + bcc).isEmpty else { throw CLIError(message: "받는 사람(--to)을 지정하세요.", isUsage: true) }
        guard let subject = options.value("--subject") else { throw CLIError(message: "제목(--subject)을 지정하세요.", isUsage: true) }
        // 본문을 생략하면 표준 입력(파이프)에서 읽는다.
        let body = options.value("--body")
            ?? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let attachments = try options.all("--attach").map { path -> Attachment in
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else { throw CLIError(message: "첨부 파일을 읽지 못했습니다: \(path)") }
            return Attachment(filename: url.lastPathComponent, mimeType: "application/octet-stream", data: data)
        }
        let message = OutgoingMessage(from: account.address, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                                      attachments: attachments)
        let data = MessageBuilder.build(message)
        if options.has("--dry-run") {
            // 보내지 않고 무엇이 나갈지만 보여준다.
            let summary: [String: Any] = [
                "dryRun": true, "from": account.email, "to": to.map(\.email), "cc": cc.map(\.email), "bcc": bcc.map(\.email),
                "subject": subject, "body": body, "attachments": attachments.map(\.filename), "bytes": data.count,
            ]
            if options.has("--json"), let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: json, as: UTF8.self))
            } else {
                print("[미리보기 — 보내지 않았습니다]\n보내는 사람: \(account.email)\n받는 사람: \((to + cc + bcc).map(\.email).joined(separator: ", "))\n제목: \(subject)\n첨부: \(attachments.count)개\n\n\(body)")
            }
            return
        }
        let password = try password(for: account)
        try SMTPClient(host: account.smtpHost, port: account.smtpPort, security: account.smtpSecurity)
            .send(username: account.username, password: password, from: account.email,
                  recipients: (to + cc + bcc).map(\.email), message: data)
        // Gmail처럼 서버가 저장해 주지 않는 계정은 보낸편지함에 사본을 넣는다 (실패해도 발송은 성공).
        if !account.serverSavesSentMail, let client = try? connect(account) {
            if let sent = try? client.listMailboxes().first(where: { $0.role == .sent }) {
                try? client.append(to: sent.path, message: data)
            }
            client.logout()
        }
        report("sent", ["to": (to + cc + bcc).map(\.email)], "보냈습니다: \((to + cc + bcc).map(\.email).joined(separator: ", "))")
    }

    // MARK: - 정리 (읽음·깃발·이동·삭제)

    /// 위치 인자를 UID 목록으로 해석한다.
    private func uids() throws -> [UInt32] {
        let values = options.positionals.compactMap { UInt32($0) }
        guard !values.isEmpty, values.count == options.positionals.count else {
            throw CLIError(message: "대상 메일의 UID를 하나 이상 숫자로 지정하세요. ‘vmail list’의 첫 열이 UID입니다.", isUsage: true)
        }
        return values
    }

    private func mark() throws {
        let changes: [(String, String, Bool)] = [("--read", "\\Seen", true), ("--unread", "\\Seen", false),
                                                 ("--flag", "\\Flagged", true), ("--unflag", "\\Flagged", false)]
        let chosen = changes.filter { options.has($0.0) }
        guard chosen.count == 1 else {
            throw CLIError(message: "--read, --unread, --flag, --unflag 중 하나를 지정하세요.", isUsage: true)
        }
        let targets = try uids()
        let client = try connect(try selectedAccount())
        defer { client.logout() }
        try client.select(try mailbox(in: client).path)
        try client.store(uids: targets, flag: chosen[0].1, add: chosen[0].2)
        report("marked", ["uids": targets, "change": String(chosen[0].0.dropFirst(2))], "표시했습니다 (\(chosen[0].0.dropFirst(2))): \(targets.count)통")
    }

    private func move() throws {
        guard let destinationName = options.value("--dest")?.lowercased() else {
            throw CLIError(message: "옮길 사서함을 --dest 로 지정하세요.", isUsage: true)
        }
        let targets = try uids()
        let client = try connect(try selectedAccount())
        defer { client.logout() }
        let all = try client.listMailboxes()
        let destination = (MailboxRole(rawValue: destinationName).flatMap { role in all.first { $0.role == role } })
            ?? all.first { $0.path.lowercased() == destinationName || $0.name.lowercased() == destinationName
                || $0.leafName.lowercased() == destinationName }
        guard let destination else { throw CLIError(message: "사서함 ‘\(destinationName)’을(를) 찾을 수 없습니다.") }
        try client.select(try mailbox(in: client).path)
        try client.move(uids: targets, to: destination.path)
        report("moved", ["uids": targets, "destination": destination.name], "‘\(destination.name)’(으)로 옮겼습니다: \(targets.count)통")
    }

    private func delete() throws {
        let targets = try uids()
        let client = try connect(try selectedAccount())
        defer { client.logout() }
        let source = try mailbox(in: client)
        let trash = try client.listMailboxes().first { $0.role == .trash }
        try client.select(source.path)
        if let trash, source.role != .trash {
            try client.move(uids: targets, to: trash.path)
            report("trashed", ["uids": targets], "휴지통으로 옮겼습니다: \(targets.count)통")
        } else {
            try client.deletePermanently(uids: targets)
            report("deleted", ["uids": targets], "완전히 삭제했습니다: \(targets.count)통")
        }
    }

    /// 계정마다 키체인 접근과 로그인을 확인한다. 키체인 허용 창은 여기서 한 번 ‘항상 허용’해 두면 된다.
    private func doctor() throws {
        struct Check: Encodable {
            let account: String
            let ok: Bool
            let detail: String
        }
        let accounts = try loadAccounts()
        guard !accounts.isEmpty else { throw CLIError(message: "등록된 계정이 없습니다. vmail 앱에서 계정을 먼저 추가하세요.") }
        let checks = accounts.map { account -> Check in
            do {
                let client = try connect(account)
                let count = try client.listMailboxes().count
                client.logout()
                return Check(account: account.email, ok: true, detail: "로그인 성공, 사서함 \(count)개")
            } catch {
                return Check(account: account.email, ok: false, detail: error.localizedDescription)
            }
        }
        if options.has("--json") {
            printJSON(checks)
        } else {
            for check in checks { print("\(check.ok ? "✓" : "✗") \(check.account) — \(check.detail)") }
        }
        if checks.contains(where: { !$0.ok }) { exit(1) }
    }

    /// Claude Code·Codex가 vmail을 알아서 쓰도록 스킬 파일을 설치한다 (해당 도구의 폴더가 있을 때만).
    private func installSkill() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var installed: [String] = []
        for tool in [".claude", ".codex"] {
            let root = home.appendingPathComponent(tool, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let folder = root.appendingPathComponent("skills/vmail", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("SKILL.md")
            try Data(AgentGuide.skill.utf8).write(to: file, options: .atomic)
            installed.append(file.path)
        }
        guard !installed.isEmpty else {
            throw CLIError(message: "~/.claude 또는 ~/.codex 폴더가 없습니다. ‘vmail agent-guide’의 내용을 에이전트 지침에 직접 넣으세요.")
        }
        report("installed", ["files": installed], "스킬을 설치했습니다:\n" + installed.joined(separator: "\n"))
    }

    /// 변경 명령의 결과를 사람용 문장 또는 JSON으로 알린다.
    private func report(_ action: String, _ details: [String: Any], _ sentence: String) {
        guard options.has("--json") else { return print(sentence) }
        let payload = details.merging(["ok": true, "action": action]) { current, _ in current }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - 출력

    private struct MessageOutput: Encodable {
        struct File: Encodable {
            let filename: String
            let mimeType: String
            let size: Int
        }
        let uid: UInt32
        let subject: String
        let from: String
        let to: String
        let cc: String
        let date: Date?
        let body: String
        let attachments: [File]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func printEnvelopes(_ envelopes: [Envelope]) {
        if options.has("--json") { return printJSON(envelopes) }
        if envelopes.isEmpty {
            print("메일이 없습니다.")
            return
        }
        for envelope in envelopes {
            let mark = (envelope.isSeen ? " " : "●") + (envelope.isFlagged ? "★" : " ")
            let sender = envelope.from.first?.displayName ?? "(보낸 사람 없음)"
            print("\(envelope.uid)\t\(mark)\t\(Self.dateFormatter.string(from: envelope.date))\t\(sender)\t\(envelope.subject)")
        }
    }

    private func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { fail("JSON으로 변환하지 못했습니다.") }
        print(String(decoding: data, as: UTF8.self))
    }

    private func save(_ attachments: [Attachment], to directory: String) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for attachment in attachments {
            // 경로 구분자를 없애 지정한 폴더 밖으로 나가지 못하게 한다.
            let name = attachment.filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            try attachment.data.write(to: folder.appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? "첨부파일" + name : name),
                                      options: .atomic)
        }
    }
}
