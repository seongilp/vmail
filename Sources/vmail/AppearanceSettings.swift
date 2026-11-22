import AppKit
import MailCore

/// 설정 폼 조립 도우미: 체크박스·팝업을 값 읽기/쓰기 클로저에 묶어 세로로 쌓는다.
final class SettingsForm {
    private final class Binding: NSObject {
        let handler: (NSControl) -> Void
        init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
        @objc func fire(_ sender: NSControl) { handler(sender) }
    }

    let stack = NSStackView()
    private var bindings: [Binding] = []

    init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
    }

    private func bind(_ control: NSControl, _ handler: @escaping (NSControl) -> Void) {
        let binding = Binding(handler)
        bindings.append(binding)
        control.target = binding
        control.action = #selector(Binding.fire(_:))
    }

    @discardableResult
    func checkbox(_ title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = isOn ? .on : .off
        bind(box) { onChange(($0 as? NSButton)?.state == .on) }
        stack.addArrangedSubview(box)
        return box
    }

    @discardableResult
    func popup(_ label: String, options: [String], selected: Int, onChange: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: options)
        popup.selectItem(at: max(0, min(selected, options.count - 1)))
        bind(popup) { onChange(($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        row([NSTextField(labelWithString: label), popup])
        return popup
    }

    func row(_ views: [NSView]) {
        let row = NSStackView(views: views)
        row.spacing = 8
        stack.addArrangedSubview(row)
    }

    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        if let previous = stack.arrangedSubviews.dropLast().last { stack.setCustomSpacing(2, after: previous) }
    }

    func gap() {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
    }

    /// 폼을 표준 여백으로 감싼, 설정 탭 크기의 뷰
    func makeView() -> NSView {
        let margin = SettingsWindowController.margin
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth),
            container.heightAnchor.constraint(equalToConstant: SettingsWindowController.contentHeight),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -margin),
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
            let caption = NSTextField(labelWithString: label)
            caption.alignment = .right
            caption.widthAnchor.constraint(equalToConstant: 84).isActive = true
            let field = NSTextField(labelWithString: "")
            field.alignment = .center
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.isBezeled = true
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let button = NSButton(title: "선택…", target: self, action: #selector(selectFont(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            fields.append(field)
            form.row([caption, field, button])
        }
        form.gap()
        form.checkbox("평문 메시지를 고정폭 글꼴로 보기", isOn: Preferences.useFixedFontForPlainText) {
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
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 12).isActive = true
        form.row([spacer] + row)
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
        form.popup("삭제한 메일 이동 위치:", options: ["휴지통", "보관함"],
                   selected: Preferences.deleteDestination == .trash ? 0 : 1) {
            Preferences.deleteDestination = $0 == 0 ? .trash : .archive
        }
        form.checkbox("삭제하거나 보관한 뒤 다음 메일 자동으로 보기", isOn: Preferences.selectNextAfterRemoval) {
            Preferences.selectNextAfterRemoval = $0
        }
        form.gap()
        form.checkbox("읽지 않은 메일을 굵게 표시", isOn: Preferences.boldUnread) { Preferences.boldUnread = $0 }
        form.checkbox("스마트 주소 사용", isOn: Preferences.smartAddresses) { Preferences.smartAddresses = $0 }
        form.note("     끄면 받는 사람의 이름과 주소를 항상 함께 표시합니다.")
        form.checkbox("메시지에 어두운 배경 사용", isOn: Preferences.darkMessageBackground) { Preferences.darkMessageBackground = $0 }
        form.note("     다크 모드에서 평문 메일에 적용됩니다. HTML 메일은 원래 디자인대로 표시합니다.")
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
        form.checkbox("입력하는 동안 맞춤법 검사", isOn: Preferences.checkSpelling) { Preferences.checkSpelling = $0 }
        let copies: [Preferences.CopySelf] = [.none, .cc, .bcc]
        form.popup("새 메일에 자동으로 나를:", options: ["넣지 않음", "참조에 넣기", "숨은 참조에 넣기"],
                   selected: copies.firstIndex(of: Preferences.copySelf) ?? 0) {
            Preferences.copySelf = copies[$0]
        }
        accountPopup = form.popup("새 메일을 보낼 계정:", options: ["지금 보고 있는 계정"], selected: 0) { [weak self] index in
            guard let self else { return }
            Preferences.defaultAccountEmail = index == 0 ? "" : self.manager.stores[index - 1].account.email
        }
        let delays = Preferences.undoSendChoices
        form.popup("발송 취소 대기 시간:", options: delays.map { $0 == 0 ? "끔" : "\($0)초" },
                   selected: delays.firstIndex(of: Preferences.undoSendDelay) ?? 0) {
            Preferences.undoSendDelay = delays[$0]
        }
        form.gap()
        form.checkbox("답장할 때 원본 메시지 인용", isOn: Preferences.quoteOriginal) { Preferences.quoteOriginal = $0 }
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
