import AppKit
import MailCore

/// 메시지 목록의 날짜 표기: 오늘은 시각, 올해는 월/일, 그 외는 연/월/일
enum ListDateFormatter {
    private static func make(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let time = make("jm")
    private static let monthDay = make("MMMd")
    private static let full = make("yyMMd")
    private static let long: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDay.string(from: date)
        }
        return full.string(from: date)
    }

    static func detailed(_ date: Date) -> String {
        long.string(from: date)
    }
}

/// 메시지 한 줄: 읽지 않음 점 · 보낸 사람 · 날짜 / 제목
final class MessageCellView: NSTableCellView {
    static let rowHeight: CGFloat = 52

    private let unreadDot = NSView()
    private let senderLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let flagView = NSImageView()
    private var isUnread = false

    init() {
        super.init(frame: .zero)
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 4
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        senderLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.font = .systemFont(ofSize: 12)
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        senderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        flagView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "깃발")
        flagView.contentTintColor = .systemOrange
        flagView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)

        for sub in [unreadDot, senderLabel, dateLabel, subjectLabel, flagView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            unreadDot.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),

            senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),

            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dateLabel.firstBaselineAnchor.constraint(equalTo: senderLabel.firstBaselineAnchor),

            subjectLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 3),
            subjectLabel.trailingAnchor.constraint(lessThanOrEqualTo: flagView.leadingAnchor, constant: -6),

            flagView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            flagView.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    /// showRecipient: 보낸편지함·임시보관함에서는 받는 사람을 보여준다.
    func configure(_ envelope: Envelope, showRecipient: Bool) {
        isUnread = !envelope.isSeen
        let people = showRecipient ? envelope.to : envelope.from
        let names = people.map(\.displayName).joined(separator: ", ")
        senderLabel.stringValue = names.isEmpty ? "(보낸 사람 없음)" : names
        subjectLabel.stringValue = envelope.subject.isEmpty ? "(제목 없음)" : envelope.subject
        dateLabel.stringValue = ListDateFormatter.short(envelope.date)
        senderLabel.font = .systemFont(ofSize: 13, weight: isUnread ? .semibold : .regular)
        unreadDot.isHidden = !isUnread
        flagView.isHidden = !envelope.isFlagged
        setAccessibilityLabel("\(isUnread ? "읽지 않음, " : "")\(senderLabel.stringValue), \(subjectLabel.stringValue)")
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        applyColors()
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        senderLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        subjectLabel.textColor = emphasized ? .alternateSelectedControlTextColor
            : (isUnread ? .labelColor : .secondaryLabelColor)
        dateLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        unreadDot.layer?.backgroundColor = (emphasized ? NSColor.white : NSColor.controlAccentColor).cgColor
    }
}
