import Foundation

/// 동기식 IMAP4rev1 클라이언트. 백그라운드 큐 하나에서만 사용한다.
public final class IMAPClient {
    private let connection: LineConnection
    private let security: ConnectionSecurity
    private var tagCounter = 0
    private var capabilities: Set<String> = []
    public private(set) var selectedPath: String?

    public init(host: String, port: Int, security: ConnectionSecurity, timeout: TimeInterval = 30) {
        connection = LineConnection(host: host, port: port, timeout: timeout)
        self.security = security
    }

    // MARK: - 세션

    public func connect() throws {
        try connection.open(security: security)
        let greeting = text(try readResponse())
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw MailError.connection("서버 인사말이 올바르지 않습니다.")
        }
        if security == .startTLS {
            try run("STARTTLS")
            try connection.startTLS()
        }
    }

    public func login(user: String, password: String) throws {
        do {
            try run("LOGIN \(Self.quote(user)) \(Self.quote(password))")
        } catch MailError.server(let message) {
            throw MailError.auth(message)
        }
        let lines = try run("CAPABILITY")
        capabilities = Set(lines.flatMap { text($0).uppercased().split(separator: " ").map(String.init) })
    }

    public func logout() {
        _ = try? run("LOGOUT")
        connection.close()
    }

    public func close() {
        connection.close()
    }

    // MARK: - 사서함

    public func listMailboxes() throws -> [Mailbox] {
        let lines = try run("LIST \"\" \"*\"")
        return Mailbox.resolvingDuplicateRoles(lines.compactMap(Self.parseListLine).filter(\.isSelectable))
    }

    @discardableResult
    public func select(_ path: String) throws -> MailboxStatus {
        selectedPath = nil
        let lines = try run("SELECT \(Self.quote(path))")
        var exists = 0
        var uidValidity: UInt32 = 0
        for line in lines {
            let parts = text(line).split(separator: " ")
            if parts.count >= 3, parts[2].uppercased() == "EXISTS", let n = Int(parts[1]) { exists = n }
            if let range = text(line).range(of: "[UIDVALIDITY ") {
                let digits = text(line)[range.upperBound...].prefix { $0.isNumber }
                uidValidity = UInt32(digits) ?? 0
            }
        }
        selectedPath = path
        return MailboxStatus(exists: exists, uidValidity: uidValidity)
    }

    public func ensureSelected(_ path: String) throws {
        if selectedPath != path { try select(path) }
    }

    public func unseenCount(_ path: String) throws -> Int {
        let lines = try run("STATUS \(Self.quote(path)) (UNSEEN)")
        for line in lines {
            guard let values = try? IMAPParser.parse(line.dropFirst(2)),
                  values.first?.stringValue?.uppercased() == "STATUS",
                  let items = values.last?.listValue else { continue }
            var i = 0
            while i + 1 < items.count {
                if items[i].stringValue?.uppercased() == "UNSEEN", let n = Int(items[i + 1].stringValue ?? "") {
                    return n
                }
                i += 2
            }
        }
        return 0
    }

    // MARK: - 메시지

    /// 시퀀스 번호 범위의 봉투 정보를 가져온다. 최신(UID 큰 순)이 앞에 온다.
    public func fetchEnvelopes(_ range: ClosedRange<Int>) throws -> [Envelope] {
        let lines = try run("FETCH \(range.lowerBound):\(range.upperBound) (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)")
        return lines.compactMap(Self.parseFetchLine).compactMap(EnvelopeParser.envelope).sorted { $0.uid > $1.uid }
    }

    /// 메시지 원문 전체. \Seen 플래그는 건드리지 않는다.
    public func fetchBody(uid: UInt32) throws -> Data {
        let lines = try run("UID FETCH \(uid) (BODY.PEEK[])")
        for line in lines {
            if let items = Self.parseFetchLine(line), let data = items["BODY[]"]?.dataValue { return data }
        }
        throw MailError.server("메시지를 찾을 수 없습니다. 이미 삭제되었을 수 있습니다.")
    }

    /// 서버에서 본문·헤더 전체를 검색한다. UID를 최신순으로 돌려준다.
    public func search(text: String) throws -> [UInt32] {
        // 한글 등 8비트 문자는 리터럴로 보내야 한다.
        let lines = try run("UID SEARCH CHARSET UTF-8 TEXT {\(text.utf8.count)}", literal: Data(text.utf8))
        var uids: [UInt32] = []
        for line in lines {
            let words = self.text(line).split(separator: " ")
            guard words.count >= 2, words[1].uppercased() == "SEARCH" else { continue }
            uids.append(contentsOf: words.dropFirst(2).compactMap { UInt32($0) })
        }
        return uids.sorted(by: >)
    }

    public func fetchEnvelopes(uids: [UInt32]) throws -> [Envelope] {
        guard !uids.isEmpty else { return [] }
        let lines = try run("UID FETCH \(Self.set(uids)) (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)")
        return lines.compactMap(Self.parseFetchLine).compactMap(EnvelopeParser.envelope).sorted { $0.uid > $1.uid }
    }

    public func createMailbox(_ path: String) throws {
        try run("CREATE \(Self.quote(path))")
    }

    public func renameMailbox(_ path: String, to newPath: String) throws {
        try run("RENAME \(Self.quote(path)) \(Self.quote(newPath))")
    }

    public func deleteMailbox(_ path: String) throws {
        if selectedPath == path {
            try run("CLOSE")
            selectedPath = nil
        }
        try run("DELETE \(Self.quote(path))")
    }

    public func store(uids: [UInt32], flag: String, add: Bool) throws {
        guard !uids.isEmpty else { return }
        try run("UID STORE \(Self.set(uids)) \(add ? "+" : "-")FLAGS.SILENT (\(flag))")
    }

    public func move(uids: [UInt32], to path: String) throws {
        guard !uids.isEmpty else { return }
        if capabilities.contains("MOVE") {
            try run("UID MOVE \(Self.set(uids)) \(Self.quote(path))")
        } else {
            try run("UID COPY \(Self.set(uids)) \(Self.quote(path))")
            try deletePermanently(uids: uids)
        }
    }

    public func deletePermanently(uids: [UInt32]) throws {
        guard !uids.isEmpty else { return }
        try store(uids: uids, flag: "\\Deleted", add: true)
        if capabilities.contains("UIDPLUS") {
            try run("UID EXPUNGE \(Self.set(uids))")
        } else {
            try run("EXPUNGE")
        }
    }

    /// 선택된 사서함의 모든 메시지에 플래그를 더한다. (빈 사서함이면 호출하지 말 것)
    public func storeAll(flag: String) throws {
        try run("STORE 1:* +FLAGS.SILENT (\(flag))")
    }

    /// 선택된 사서함의 모든 메시지를 완전히 삭제한다.
    public func expungeAll() throws {
        try storeAll(flag: "\\Deleted")
        try run("EXPUNGE")
    }

    public func append(to path: String, message: Data, flags: [String] = ["\\Seen"]) throws {
        try run("APPEND \(Self.quote(path)) (\(flags.joined(separator: " "))) {\(message.count)}", literal: message)
    }

    // MARK: - 명령 실행

    /// 명령을 보내고 태그 응답까지 읽는다. 그 사이의 untagged 응답 줄들을 돌려준다.
    @discardableResult
    private func run(_ command: String, literal: Data? = nil) throws -> [Data] {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        try connection.write("\(tag) \(command)\r\n")
        var untagged: [Data] = []
        var pendingLiteral = literal
        let tagPrefix = Data("\(tag) ".utf8)

        while true {
            let response = try readResponse()
            if response.starts(with: tagPrefix) {
                let status = text(response.dropFirst(tagPrefix.count))
                if status.uppercased().hasPrefix("OK") { return untagged }
                // "NO [CODE] 설명" 에서 상태 단어(NO/BAD)를 뗀 설명만 전달한다.
                let detail = status.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? status
                throw MailError.server(detail)
            }
            if response.first == UInt8(ascii: "+"), let data = pendingLiteral {
                try connection.write(data + Data("\r\n".utf8))
                pendingLiteral = nil
                continue
            }
            if response.starts(with: Data("* BYE".utf8)) {
                throw MailError.connection("서버가 세션을 종료했습니다.")
            }
            untagged.append(response)
        }
    }

    /// 리터럴({n} + n바이트)이 이어지는 줄을 하나의 논리 응답으로 합쳐 읽는다.
    private func readResponse() throws -> Data {
        var response = Data()
        while true {
            let line = try connection.readLine()
            response.append(line)
            guard let count = Self.trailingLiteralLength(line) else { return response }
            response.append(Data("\r\n".utf8))
            response.append(try connection.readBytes(count))
        }
    }

    static func trailingLiteralLength(_ line: Data) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        let digits = String(decoding: line[(open + 1)..<(line.endIndex - 1)], as: UTF8.self)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    // MARK: - 파싱 도우미

    private func text<D: DataProtocol>(_ data: D) -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func set(_ uids: [UInt32]) -> String {
        uids.map(String.init).joined(separator: ",")
    }

    /// "* LIST (\attrs) "/" name" 한 줄을 Mailbox로.
    static func parseListLine(_ line: Data) -> Mailbox? {
        guard line.starts(with: Data("* LIST ".utf8)) || line.starts(with: Data("* list ".utf8)),
              let values = try? IMAPParser.parse(line.dropFirst(2)), values.count >= 4,
              let attrs = values[1].listValue, let path = values[3].stringValue else { return nil }
        return Mailbox(path: path, name: ModifiedUTF7.decode(path), delimiter: values[2].stringValue,
                       attributes: attrs.compactMap(\.stringValue))
    }

    /// "* n FETCH (KEY value ...)" 한 줄을 [KEY: value]로.
    static func parseFetchLine(_ line: Data) -> [String: IMAPValue]? {
        let head = String(decoding: line.prefix(32), as: UTF8.self).uppercased()
        guard head.hasPrefix("* "), head.contains(" FETCH ") else { return nil }
        guard let values = try? IMAPParser.parse(line.dropFirst(2)), values.count >= 3,
              let items = values[2].listValue else { return nil }
        var result: [String: IMAPValue] = [:]
        var i = 0
        while i + 1 < items.count {
            if let key = items[i].stringValue { result[key.uppercased()] = items[i + 1] }
            i += 2
        }
        return result
    }
}

/// FETCH 응답 항목 → Envelope
enum EnvelopeParser {
    private static let internalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static func envelope(_ items: [String: IMAPValue]) -> Envelope? {
        guard let uidText = items["UID"]?.stringValue, let uid = UInt32(uidText),
              let env = items["ENVELOPE"]?.listValue, env.count >= 10 else { return nil }
        let internalDate = items["INTERNALDATE"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let date = internalDateFormatter.date(from: internalDate)
            ?? MessageDate.parse(env[0].stringValue ?? "")
            ?? Date(timeIntervalSince1970: 0)
        return Envelope(
            uid: uid,
            flags: items["FLAGS"]?.listValue?.compactMap(\.stringValue) ?? [],
            date: date,
            size: Int(items["RFC822.SIZE"]?.stringValue ?? "") ?? 0,
            subject: HeaderCoding.decode(env[1].stringValue ?? "").replacingOccurrences(of: "\r\n", with: ""),
            from: addresses(env[2]),
            to: addresses(env[5]),
            cc: addresses(env[6]),
            replyTo: addresses(env[4]),
            messageID: env[9].stringValue
        )
    }

    /// ((name adl mailbox host) ...) → [Address]
    static func addresses(_ value: IMAPValue) -> [Address] {
        guard let list = value.listValue else { return [] }
        return list.compactMap { entry in
            guard let parts = entry.listValue, parts.count >= 4,
                  let mailbox = parts[2].stringValue, let host = parts[3].stringValue else { return nil }
            let name = parts[0].stringValue.map(HeaderCoding.decode)
            return Address(name: name, email: "\(mailbox)@\(host)")
        }
    }
}

/// RFC 5322 Date 헤더 파싱/생성
public enum MessageDate {
    private static let formats = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"]
    private static let formatters: [DateFormatter] = formats.map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    public static func parse(_ text: String) -> Date? {
        // "(KST)" 같은 꼬리 주석 제거
        let cleaned = text.components(separatedBy: "(")[0].trimmingCharacters(in: .whitespaces)
        for f in formatters {
            if let date = f.date(from: cleaned) { return date }
        }
        return nil
    }

    public static func format(_ date: Date) -> String {
        formatters[0].string(from: date)
    }
}
