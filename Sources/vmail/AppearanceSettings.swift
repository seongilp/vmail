import AppKit
import MailCore

/// 설정 폼 조립 도우미. macOS 설정 창 표준대로 2열(오른쪽 정렬 레이블 | 컨트롤)로 쌓고 창 가운데에 둔다.
final class SettingsForm {
    private final class Binding: NSObject {
        let handler: (NSControl) -> Void
        init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
        @objc func fire(_ sender: NSControl) { handler(sender) }
    }

    private static let noteWidth: CGFloat = 360
    private static let noteIndent: CGFloat = 20   // 체크박스 글자 시작 위치에 맞춘다

    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private var bindings: [Binding] = []
    private var pendingGap = false

    init() {
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
    }

    private func bind(_ control: NSControl, _ handler: @escaping (NSControl) -> Void) {
        let binding = Binding(handler)
        bindings.append(binding)
        control.target = binding
        control.action = #selector(Binding.fire(_:))
    }

    /// 한 줄을 넣는다. label이 nil이면 레이블 칸을 비운다.
    @discardableResult
    private func add(_ label: String?, _ control: NSView, centered: Bool = false) -> NSGridRow {
        let caption: NSView = label.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView
        let row = grid.addRow(with: [caption, control])
        if centered {
            row.rowAlignment = .none
            row.yPlacement = .center
        }
        if pendingGap {
            row.topPadding = 10
            pendingGap = false
        }
        return row
    }

    @discardableResult
    func checkbox(_ title: String, label: String? = nil, isOn: Bool, onChange: @escaping (Bool) -> Void) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = isOn ? .on : .off
        bind(box) { onChange(($0 as? NSButton)?.state == .on) }
        add(label, box)
        return box
    }

    @discardableResult
    func popup(_ label: String, options: [String], selected: Int, onChange: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        popup.selectItem(at: max(0, min(selected, options.count - 1)))
        bind(popup) { onChange(($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        add(label, popup)
        return popup
    }

    /// 여러 컨트롤을 가로로 나란히 둔 줄
    func row(_ label: String? = nil, _ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        add(label, stack, centered: true)
    }

    /// 바로 위 항목에 대한 작은 설명 (indented: 체크박스 글자에 맞춰 들여쓴다)
    func note(_ text: String, indented: Bool = true) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.noteWidth
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: indented ? Self.noteIndent : 0).isActive = true
        let stack = NSStackView(views: [spacer, label])
        stack.spacing = 0
        add(nil, stack).topPadding = -3
    }

    /// 다음 줄 위에 묶음 사이 간격을 둔다.
    func gap() {
        pendingGap = true
    }

    /// 폼을 표준 여백으로 감싼 뷰. 높이는 내용에 딱 맞춘다 — 창이 탭마다 이 크기로 줄어든다.
    func makeView() -> NSView {
        let margin = SettingsWindowController.margin
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: margin),
        ])
        return container
    }
}

/// 설정 › 글꼴 및 색상
final class FontsSettingsViewController: NSViewController, NSFontChanging {
    private enum Target: Int { case list, message, fixed }

    private let form = SettingsForm()
    private var fields: [NSTextField] = []
    private var wells: [NSColorWell] = []
    private var editing = Target.list

    override func loadView() {
        for (index, label) in ["메시지 목록:", "메시지 본문:", "고정폭:"].enumerated() {
            let field = NSTextField(labelWithString: "")
            field.alignment = .center
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.isBezeled = true
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
            let button = NSButton(title: "선택…", target: self, action: #selector(selectFont(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            fields.append(field)
            form.row(label, [field, button])
        }
        form.gap()
        form.checkbox("평문 메시지를 고정폭 글꼴로 보기", label: "본문:", isOn: Preferences.useFixedFontForPlainText) {
            Preferences.useFixedFontForPlainText = $0
        }
        form.checkbox("인용문에 색 입히기", isOn: Preferences.colorQuotedText) { [weak self] isOn in
            Preferences.colorQuotedText = isOn
            self?.wells.forEach { $0.isEnabled = isOn }
        }
        var row: [NSView] = []
        for (index, title) in ["1단계", "2단계", "3단계"].enumerated() {
            let well = NSColorWell(style: .minimal)
            well.color = NSColor(hex: Preferences.quoteColors[index]) ?? .systemPurple
            well.isEnabled = Preferences.colorQuotedText
            well.target = self
            well.action = #selector(colorChanged)
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: 20).isActive = true
            wells.append(well)
            row += [NSTextField(labelWithString: title), well]
        }
        form.row("인용 색:", row)
        view = form.makeView()
        updateFields()
    }

    private func updateFields() {
        for (field, font) in zip(fields, [Preferences.listFont, Preferences.messageFont, Preferences.fixedFont]) {
            let name = font.fontName.hasPrefix(".") ? "시스템 글꼴" : (font.displayName ?? font.fontName)
            field.stringValue = "\(name) \(Int(font.pointSize))"
            field.font = NSFontManager.shared.convert(font, toSize: 12)
        }
    }

    private func currentFont(_ target: Target) -> NSFont {
        switch target {
        case .list: return Preferences.listFont
        case .message: return Preferences.messageFont
        case .fixed: return Preferences.fixedFont
        }
    }

    @objc private func selectFont(_ sender: NSButton) {
        editing = Target(rawValue: sender.tag) ?? .list
        view.window?.makeFirstResponder(self)
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(currentFont(editing), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    /// 글꼴 패널에서 고른 글꼴을 저장한다.
    func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let font = sender.convert(currentFont(editing))
        switch editing {
        case .list: Preferences.listFont = font
        case .message: Preferences.messageFont = font
        case .fixed: Preferences.fixedFont = font
        }
        updateFields()
    }

    @objc private func colorChanged() {
        Preferences.quoteColors = wells.map(\.color.hexString)
    }
}

/// 설정 › 보기
final class ViewingSettingsViewController: NSViewController {
    private let form = SettingsForm()

    override func loadView() {
        form.popup("삭제한 메일:", options: ["휴지통", "보관함"],
                   selected: Preferences.deleteDestination == .trash ? 0 : 1) {
            Preferences.deleteDestination = $0 == 0 ? .trash : .archive
        }
        form.checkbox("삭제하거나 보관한 뒤 다음 메일 자동으로 보기", isOn: Preferences.selectNextAfterRemoval) {
            Preferences.selectNextAfterRemoval = $0
        }
        form.gap()
        form.checkbox("읽지 않은 메일을 굵게 표시", label: "표시:", isOn: Preferences.boldUnread) { Preferences.boldUnread = $0 }
        form.checkbox("스마트 주소 사용", isOn: Preferences.smartAddresses) { Preferences.smartAddresses = $0 }
        form.note("끄면 받는 사람의 이름과 주소를 항상 함께 표시합니다.")
        form.checkbox("메시지에 어두운 배경 사용", isOn: Preferences.darkMessageBackground) { Preferences.darkMessageBackground = $0 }
        form.note("다크 모드에서 평문 메일에 적용됩니다. HTML 메일은 원래 디자인대로 표시합니다.")
        form.gap()
        let behaviors: [Preferences.MarkRead] = [.immediately, .delayed, .manual]
        form.popup("읽음 처리:", options: ["메일을 열면 바로", "\(Int(Preferences.markReadDelay))초 뒤", "직접 표시할 때만"],
                   selected: behaviors.firstIndex(of: Preferences.markRead) ?? 0) {
            Preferences.markRead = behaviors[$0]
        }
        view = form.makeView()
    }
}

/// 설정 › 작성
final class ComposingSettingsViewController: NSViewController {
    private let manager: AccountManager
    private let form = SettingsForm()
    private var accountPopup: NSPopUpButton?

    init(manager: AccountManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 미지원") }

    override func loadView() {
        form.checkbox("입력하는 동안 맞춤법 검사", label: "맞춤법:", isOn: Preferences.checkSpelling) { Preferences.checkSpelling = $0 }
        let copies: [Preferences.CopySelf] = [.none, .cc, .bcc]
        form.popup("자동으로 나를:", options: ["넣지 않음", "참조에 넣기", "숨은 참조에 넣기"],
                   selected: copies.firstIndex(of: Preferences.copySelf) ?? 0) {
            Preferences.copySelf = copies[$0]
        }
        accountPopup = form.popup("보내는 계정:", options: ["지금 보고 있는 계정"], selected: 0) { [weak self] index in
            guard let self else { return }
            Preferences.defaultAccountEmail = index == 0 ? "" : self.manager.stores[index - 1].account.email
        }
        let delays = Preferences.undoSendChoices
        form.popup("발송 취소 대기:", options: delays.map { $0 == 0 ? "끔" : "\($0)초" },
                   selected: delays.firstIndex(of: Preferences.undoSendDelay) ?? 0) {
            Preferences.undoSendDelay = delays[$0]
        }
        form.gap()
        form.checkbox("답장할 때 원본 메시지 인용", label: "답장:", isOn: Preferences.quoteOriginal) { Preferences.quoteOriginal = $0 }
        form.checkbox("인용문 앞에 ‘>’ 붙이기 (인용 단계 높이기)", isOn: Preferences.increaseQuoteLevel) {
            Preferences.increaseQuoteLevel = $0
        }
        view = form.makeView()
    }

    /// 계정 목록은 바뀔 수 있으므로 탭을 열 때마다 다시 채운다.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard let accountPopup else { return }
        let emails = manager.stores.map(\.account.email)
        accountPopup.removeAllItems()
        accountPopup.addItems(withTitles: ["지금 보고 있는 계정"] + emails)
        let index = emails.firstIndex { $0.lowercased() == Preferences.defaultAccountEmail.lowercased() }
        accountPopup.selectItem(at: index.map { $0 + 1 } ?? 0)
    }
}
