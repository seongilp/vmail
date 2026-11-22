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

/// 목록의 한 줄. 대화로 묶었을 때는 대화의 최신 메일이 머리 줄이 되고, 펼치면 나머지가 하위 줄로 나온다.
struct MessageRow {
    /// 이 줄에 보여줄 메일
    let envelope: Envelope
    /// 이 줄에 대한 동작(삭제·읽음 등)이 적용될 메일들. 접힌 대화는 전체, 그 외에는 이 메일 하나.
    let targets: [Envelope]
    /// 대화에 든 메일 수 (1이면 단독 메일)
    let threadCount: Int
    /// 대화를 식별하는 값 (대화에서 가장 오래된 메일의 UID)
    let threadKey: UInt32
    let isExpanded: Bool
    /// 펼친 대화의 하위 줄인지
    let isChild: Bool

    var isThreadHeader: Bool { threadCount > 1 && !isChild }
    var isUnread: Bool { targets.contains { !$0.isSeen } }
    var isFlagged: Bool { targets.contains(where: \.isFlagged) }
}

/// 메시지 한 줄: 읽지 않음 점 · 보낸 사람 · 날짜 / 제목 · 대화 개수 / 본문 미리보기
final class MessageCellView: NSTableCellView {
    private static let childIndent: CGFloat = 14

    /// 목록 글꼴 크기와 미리보기 줄 수에 맞춘 줄 높이
    static var rowHeight: CGFloat {
        let size = Preferences.listFont.pointSize
        return ceil(size * 2.3) + 22 + CGFloat(Preferences.listPreviewLines) * ceil((size - 1) * 1.3)
    }

    /// 대화 개수 배지를 눌렀을 때 (접기/펼치기)
    var onToggleThread: (() -> Void)?

    private let unreadDot = NSView()
    private let senderLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let flagView = NSImageView()
    private let countButton = NSButton(title: "", target: nil, action: nil)
    private var leading: NSLayoutConstraint?
    private var isUnread = false

    init() {
        super.init(frame: .zero)
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 4
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        senderLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.lineBreakMode = .byTruncatingTail
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.cell?.truncatesLastVisibleLine = true
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        for label in [senderLabel, subjectLabel, previewLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        flagView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "깃발")
        flagView.contentTintColor = .systemOrange
        flagView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)

        countButton.bezelStyle = .inline
        countButton.controlSize = .mini
        countButton.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        countButton.target = self
        countButton.action = #selector(toggleThread)
        countButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        countButton.setContentHuggingPriority(.required, for: .horizontal)

        for sub in [unreadDot, senderLabel, dateLabel, subjectLabel, previewLabel, flagView, countButton] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        let leading = senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            unreadDot.trailingAnchor.constraint(equalTo: senderLabel.leadingAnchor, constant: -6),
            unreadDot.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),

            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),

            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dateLabel.firstBaselineAnchor.constraint(equalTo: senderLabel.firstBaselineAnchor),

            subjectLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 3),
            subjectLabel.trailingAnchor.constraint(lessThanOrEqualTo: flagView.leadingAnchor, constant: -6),

            countButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            countButton.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),
            flagView.trailingAnchor.constraint(equalTo: countButton.leadingAnchor, constant: -4),
            flagView.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),

            previewLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 2),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    @objc private func toggleThread() {
        onToggleThread?()
    }

    /// showRecipient: 보낸편지함·임시보관함에서는 받는 사람을 보여준다. preview: 본문 미리보기(없으면 nil).
    func configure(_ row: MessageRow, showRecipient: Bool, preview: String?) {
        let envelope = row.envelope
        isUnread = row.isUnread
        let people = showRecipient ? envelope.to : envelope.from
        let names = people.map(\.displayName).joined(separator: ", ")
        senderLabel.stringValue = names.isEmpty ? "(보낸 사람 없음)" : names
        subjectLabel.stringValue = envelope.subject.isEmpty ? "(제목 없음)" : envelope.subject
        dateLabel.stringValue = ListDateFormatter.short(envelope.date)

        let base = Preferences.listFont
        let emphasized = isUnread && Preferences.boldUnread
        if base.fontName.hasPrefix(".") {
            senderLabel.font = .systemFont(ofSize: base.pointSize, weight: emphasized ? .semibold : .regular)
        } else {
            senderLabel.font = emphasized ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        }
        let small = NSFontManager.shared.convert(base, toSize: base.pointSize - 1)
        subjectLabel.font = small
        previewLabel.font = small
        dateLabel.font = NSFontManager.shared.convert(base, toSize: base.pointSize - 2)

        let lines = Preferences.listPreviewLines
        previewLabel.isHidden = lines == 0
        previewLabel.maximumNumberOfLines = max(1, lines)
        previewLabel.stringValue = preview ?? ""

        leading?.constant = 18 + (row.isChild ? Self.childIndent : 0)
        unreadDot.isHidden = !isUnread
        flagView.isHidden = !row.isFlagged
        countButton.isHidden = !row.isThreadHeader
        countButton.title = row.isExpanded ? "\(row.threadCount) ▾" : "\(row.threadCount) ▸"
        countButton.toolTip = row.isExpanded ? "대화 접기" : "대화 펼치기 (메일 \(row.threadCount)통)"

        var label = "\(isUnread ? "읽지 않음, " : "")\(senderLabel.stringValue), \(subjectLabel.stringValue)"
        if row.isThreadHeader { label += ", 대화 \(row.threadCount)통" }
        setAccessibilityLabel(label)
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        let selected = NSColor.alternateSelectedControlTextColor
        senderLabel.textColor = emphasized ? selected : .labelColor
        subjectLabel.textColor = emphasized ? selected : (isUnread ? .labelColor : .secondaryLabelColor)
        previewLabel.textColor = emphasized ? selected.withAlphaComponent(0.85) : .tertiaryLabelColor
        dateLabel.textColor = emphasized ? selected : .secondaryLabelColor
        unreadDot.layer?.backgroundColor = (emphasized ? NSColor.white : NSColor.controlAccentColor).cgColor
    }
}
