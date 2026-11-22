import AppKit
import MailCore

/// 사용자 설정 (UserDefaults). 값이 바뀌면 didChange 알림을 보내 열린 화면이 바로 반영한다.
enum Preferences {
    static let didChange = Notification.Name("Preferences.didChange")

    enum DeleteDestination: String { case trash, archive }
    enum MarkRead: String { case immediately, delayed, manual }
    enum CopySelf: String { case none, cc, bcc }

    /// ‘읽음 처리: 잠시 후’의 대기 시간
    static let markReadDelay: TimeInterval = 2
    static let undoSendChoices = [0, 5, 10, 20, 30]
    static let defaultQuoteColors = ["#BF5AF2", "#32ADE6", "#34C759"]

    // MARK: - 저장 도우미

    /// 내보내기·가져오기 대상인 단순 값 키와 기본값
    private static let simpleDefaults: [String: Any] = [
        "signature": "", "alwaysLoadRemoteContent": false, "notifyNewMail": true,
        "listFontName": "", "listFontSize": 13.0, "messageFontName": "", "messageFontSize": 14.0,
        "fixedFontName": "Menlo", "fixedFontSize": 12.0, "useFixedFontForPlainText": false,
        "colorQuotedText": true, "quoteColor0": defaultQuoteColors[0], "quoteColor1": defaultQuoteColors[1],
        "quoteColor2": defaultQuoteColors[2],
        "deleteDestination": DeleteDestination.trash.rawValue, "selectNextAfterRemoval": true,
        "boldUnread": true, "smartAddresses": true, "darkMessageBackground": true,
        "listPreviewLines": 1, "groupByConversation": true,
        "markRead": MarkRead.immediately.rawValue,
        "checkSpelling": true, "copySelf": CopySelf.none.rawValue, "defaultAccountEmail": "",
        "undoSendDelay": 0, "quoteOriginal": true, "increaseQuoteLevel": true,
        SignatureUse.newMail.rawValue: "", SignatureUse.reply.rawValue: "", SignatureUse.autoReply.rawValue: "",
    ]

    private static func get<T>(_ key: String) -> T {
        if let value = UserDefaults.standard.object(forKey: key) as? T { return value }
        guard let fallback = simpleDefaults[key] as? T else { fatalError("설정 키 \(key) 의 기본값이 없습니다") }
        return fallback
    }

    private static func set(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 단순 값 전체를 문자열로 (설정 내보내기)
    static func snapshot() -> [String: String] {
        simpleDefaults.keys.reduce(into: [:]) { result, key in
            let value = UserDefaults.standard.object(forKey: key) ?? simpleDefaults[key] ?? ""
            result[key] = "\(value)"
        }
    }

    /// 문자열로 저장된 값을 기본값의 타입에 맞춰 되돌린다 (설정 가져오기). 모르는 키·형식이 틀린 값은 건너뛴다.
    static func restore(_ values: [String: String]) {
        for (key, text) in values {
            switch simpleDefaults[key] {
            case is Bool: if let value = Bool(text) ?? (Int(text).map { $0 != 0 }) { UserDefaults.standard.set(value, forKey: key) }
            case is Int: if let value = Int(text) { UserDefaults.standard.set(value, forKey: key) }
            case is Double: if let value = Double(text) { UserDefaults.standard.set(value, forKey: key) }
            case is String: UserDefaults.standard.set(text, forKey: key)
            default: continue
            }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: - 일반

    static var signature: String {
        get { get("signature") }
        set { set("signature", newValue) }
    }

    /// 원격 이미지를 묻지 않고 항상 불러올지 (기본: 차단)
    static var alwaysLoadRemoteContent: Bool {
        get { get("alwaysLoadRemoteContent") }
        set { set("alwaysLoadRemoteContent", newValue) }
    }

    static var notifyNewMail: Bool {
        get { get("notifyNewMail") }
        set { set("notifyNewMail", newValue) }
    }

    // MARK: - 서명

    private static let signaturesKey = "signatures"

    /// 서명 목록. 예전의 단일 서명이 있으면 처음 한 번 ‘기본’ 서명으로 옮긴다.
    static var signatures: [Signature] {
        get {
            if let stored = decode([Signature].self, signaturesKey) { return stored }
            let legacy = signature.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !legacy.isEmpty else { return [] }
            let migrated = Signature(id: UUID(), name: "기본", text: legacy)
            encode([migrated], signaturesKey)
            UserDefaults.standard.set(migrated.id.uuidString, forKey: SignatureUse.newMail.rawValue)
            UserDefaults.standard.set(migrated.id.uuidString, forKey: SignatureUse.reply.rawValue)
            return [migrated]
        }
        set {
            encode(newValue, signaturesKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// 용도에 지정된 서명 (지정하지 않았거나 지워졌으면 nil)
    static func signature(for use: SignatureUse) -> Signature? {
        let all = signatures   // 먼저 읽어 이전 서명을 옮긴다
        let id: String = get(use.rawValue)
        return all.first { $0.id.uuidString == id }
    }

    static func setSignature(_ signature: Signature?, for use: SignatureUse) {
        set(use.rawValue, signature?.id.uuidString ?? "")
    }

    // MARK: - 글꼴 및 색상

    /// 이름이 비어 있으면 시스템 글꼴
    private static func font(_ nameKey: String, _ sizeKey: String, fallback: (CGFloat) -> NSFont) -> NSFont {
        let name: String = get(nameKey)
        let size = CGFloat(get(sizeKey) as Double)
        return (name.isEmpty ? nil : NSFont(name: name, size: size)) ?? fallback(size)
    }

    private static func setFont(_ font: NSFont?, _ nameKey: String, _ sizeKey: String) {
        guard let font else { return }
        // 시스템 글꼴은 이름으로 다시 만들 수 없으므로 빈 이름으로 저장한다.
        let isSystem = font.fontName.hasPrefix(".")
        UserDefaults.standard.set(isSystem ? "" : font.fontName, forKey: nameKey)
        set(sizeKey, Double(font.pointSize))
    }

    static var listFont: NSFont {
        get { font("listFontName", "listFontSize") { .systemFont(ofSize: $0) } }
        set { setFont(newValue, "listFontName", "listFontSize") }
    }

    static var messageFont: NSFont {
        get { font("messageFontName", "messageFontSize") { .systemFont(ofSize: $0) } }
        set { setFont(newValue, "messageFontName", "messageFontSize") }
    }

    static var fixedFont: NSFont {
        get { font("fixedFontName", "fixedFontSize") { .monospacedSystemFont(ofSize: $0, weight: .regular) } }
        set { setFont(newValue, "fixedFontName", "fixedFontSize") }
    }

    static var useFixedFontForPlainText: Bool {
        get { get("useFixedFontForPlainText") }
        set { set("useFixedFontForPlainText", newValue) }
    }

    static var colorQuotedText: Bool {
        get { get("colorQuotedText") }
        set { set("colorQuotedText", newValue) }
    }

    /// 인용 단계별 색 (#RRGGBB) 3개
    static var quoteColors: [String] {
        get { (0..<3).map { get("quoteColor\($0)") } }
        set { for (index, hex) in newValue.prefix(3).enumerated() { set("quoteColor\(index)", hex) } }
    }

    // MARK: - 보기

    static var deleteDestination: DeleteDestination {
        get { DeleteDestination(rawValue: get("deleteDestination")) ?? .trash }
        set { set("deleteDestination", newValue.rawValue) }
    }

    /// 삭제·보관 후 다음 메일을 자동으로 선택할지
    static var selectNextAfterRemoval: Bool {
        get { get("selectNextAfterRemoval") }
        set { set("selectNextAfterRemoval", newValue) }
    }

    /// 목록에 보여줄 본문 미리보기 줄 수 (0이면 숨김)
    static var listPreviewLines: Int {
        get { max(0, min(2, get("listPreviewLines") as Int)) }
        set { set("listPreviewLines", newValue) }
    }

    /// 같은 대화의 메일을 한 줄로 묶어 보여줄지
    static var groupByConversation: Bool {
        get { get("groupByConversation") }
        set { set("groupByConversation", newValue) }
    }

    static var boldUnread: Bool {
        get { get("boldUnread") }
        set { set("boldUnread", newValue) }
    }

    /// 켜면 이름만, 끄면 이름과 주소를 함께 보여준다.
    static var smartAddresses: Bool {
        get { get("smartAddresses") }
        set { set("smartAddresses", newValue) }
    }

    static var darkMessageBackground: Bool {
        get { get("darkMessageBackground") }
        set { set("darkMessageBackground", newValue) }
    }

    static var markRead: MarkRead {
        get { MarkRead(rawValue: get("markRead")) ?? .immediately }
        set { set("markRead", newValue.rawValue) }
    }

    // MARK: - 작성

    static var checkSpelling: Bool {
        get { get("checkSpelling") }
        set { set("checkSpelling", newValue) }
    }

    static var copySelf: CopySelf {
        get { CopySelf(rawValue: get("copySelf")) ?? .none }
        set { set("copySelf", newValue.rawValue) }
    }

    /// 새 메일을 보낼 계정. 비어 있으면 지금 보고 있는 계정.
    static var defaultAccountEmail: String {
        get { get("defaultAccountEmail") }
        set { set("defaultAccountEmail", newValue) }
    }

    /// 보내기를 누른 뒤 실제 발송까지 기다리는 초 (0이면 바로 보냄)
    static var undoSendDelay: Int {
        get { get("undoSendDelay") }
        set { set("undoSendDelay", newValue) }
    }

    static var quoteOriginal: Bool {
        get { get("quoteOriginal") }
        set { set("quoteOriginal", newValue) }
    }

    /// 인용문 각 줄 앞에 ‘>’ 를 붙일지
    static var increaseQuoteLevel: Bool {
        get { get("increaseQuoteLevel") }
        set { set("increaseQuoteLevel", newValue) }
    }

    // MARK: - 부재중 자동 응답 / 규칙 (구조가 있는 값)

    private static let autoReplyKey = "autoReply"
    private static let autoReplyLogKey = "autoReplyLog"
    private static let rulesKey = "rules"

    static var autoReply: AutoReplySettings {
        get { decode(AutoReplySettings.self, autoReplyKey) ?? AutoReplySettings() }
        set { encode(newValue, autoReplyKey) }
    }

    /// 자동 응답을 보낸 상대와 시각 (같은 사람에게 반복해서 보내지 않기 위한 기록)
    static var autoReplyLog: [String: Date] {
        get { decode([String: Date].self, autoReplyLogKey) ?? [:] }
        set { encode(newValue, autoReplyLogKey) }
    }

    static var rules: [MailRule] {
        get { decode([MailRule].self, rulesKey) ?? [] }
        set { encode(newValue, rulesKey) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("vmail: 설정 해석 실패(\(key)) — \(error.localizedDescription)")
            return nil
        }
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            NSLog("vmail: 설정 저장 실패(\(key)) — \(error.localizedDescription)")
        }
    }
}

/// 이름 붙인 서명 하나
struct Signature: Codable, Equatable {
    var id: UUID
    var name: String
    var text: String
}

/// 서명을 쓰는 곳 (rawValue는 저장 키)
enum SignatureUse: String, CaseIterable {
    case newMail = "signatureForNewMail"
    case reply = "signatureForReply"
    case autoReply = "signatureForAutoReply"

    var title: String {
        switch self {
        case .newMail: return "새 메일"
        case .reply: return "답장·전달"
        case .autoReply: return "부재중 응답"
        }
    }
}

extension NSColor {
    /// "#RRGGBB" → 색. 형식이 틀리면 nil.
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
    }
}
