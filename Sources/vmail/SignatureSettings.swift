import AppKit

/// 설정 › 서명: 서명 여러 개를 만들고, 용도별(새 메일 / 답장·전달 / 부재중 응답)로 지정한다.
final class SignaturesSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                              NSTextFieldDelegate, NSTextViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("signature")
    private static let listWidth: CGFloat = 150
    private static let editorHeight: CGFloat = 150

    private let tableView = NSTableView()
    private let controls = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "plus", accessibilityDescription: "서명 추가") ?? NSImage(),
        NSImage(systemSymbolName: "minus", accessibilityDescription: "서명 제거") ?? NSImage(),
    ], trackingMode: .momentary, target: nil, action: nil)
    private let nameField = NSTextField()
    private let textView = NSTextView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "+ 를 눌러 서명을 만드세요.")
    private var usePopups: [(use: SignatureUse, popup: NSPopUpButton)] = []
    private var signatures: [Signature] = []
    private var isLoading = false

    override func loadView() {
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("서명")
        let listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder

        controls.segmentStyle = .smallSquare
        controls.target = self
        controls.action = #selector(controlClicked)

        nameField.placeholderString = "서명 이름"
        nameField.delegate = self
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("서명 내용")
        let editorScroll = NSScrollView()
        editorScroll.documentView = textView
        editorScroll.hasVerticalScroller = true
        editorScroll.borderType = .bezelBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        // 용도별 지정: 한 줄에 나란히
        var useViews: [NSView] = []
        for use in SignatureUse.allCases {
            let popup = NSPopUpButton()
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.target = self
            popup.action = #selector(useChanged(_:))
            popup.tag = usePopups.count
            usePopups.append((use, popup))
            let label = NSTextField(labelWithString: "\(use.title):")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            useViews += [label, popup]
        }
        let uses = NSStackView(views: useViews)
        uses.spacing = 6
        for index in stride(from: 1, to: useViews.count - 1, by: 2) { uses.setCustomSpacing(16, after: useViews[index]) }

        let margin = SettingsWindowController.margin
        let container = NSView()
        for sub in [listScroll, controls, nameField, editorScroll, emptyLabel, uses] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsWindowController.contentWidth),
            listScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            listScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            listScroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            listScroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: 1),
            controls.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            controls.bottomAnchor.constraint(equalTo: editorScroll.bottomAnchor),
            nameField.topAnchor.constraint(equalTo: listScroll.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            editorScroll.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            editorScroll.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            editorScroll.heightAnchor.constraint(equalToConstant: Self.editorHeight),
            emptyLabel.centerYAnchor.constraint(equalTo: editorScroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: editorScroll.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: editorScroll.trailingAnchor, constant: -12),
            uses.topAnchor.constraint(equalTo: editorScroll.bottomAnchor, constant: 12),
            uses.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            uses.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),
            uses.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        signatures = Preferences.signatures
        reload(selecting: signatures.isEmpty ? nil : max(0, tableView.selectedRow))
    }

    private var selected: Int? {
        let row = tableView.selectedRow
        return row >= 0 && row < signatures.count ? row : nil
    }

    private func reload(selecting row: Int?) {
        isLoading = true
        tableView.reloadData()
        if let row, row < signatures.count {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        isLoading = false
        showSelection()
        reloadUsePopups()
    }

    private func showSelection() {
        isLoading = true
        defer { isLoading = false }
        let signature = selected.map { signatures[$0] }
        nameField.stringValue = signature?.name ?? ""
        textView.string = signature?.text ?? ""
        nameField.isEnabled = signature != nil
        textView.isEditable = signature != nil
        emptyLabel.isHidden = signature != nil
        controls.setEnabled(signature != nil, forSegment: 1)
    }

    private func reloadUsePopups() {
        for (use, popup) in usePopups {
            popup.removeAllItems()
            popup.addItems(withTitles: ["없음"] + signatures.map(\.name))
            let current = Preferences.signature(for: use)
            popup.selectItem(at: signatures.firstIndex { $0.id == current?.id }.map { $0 + 1 } ?? 0)
        }
    }

    private func save(_ next: [Signature]) {
        signatures = next
        Preferences.signatures = next
    }

    // MARK: - 액션

    @objc private func controlClicked() {
        if controls.selectedSegment == 0 {
            save(signatures + [Signature(id: UUID(), name: "서명 \(signatures.count + 1)", text: "")])
            reload(selecting: signatures.count - 1)
            view.window?.makeFirstResponder(textView)
        } else if let row = selected {
            save(signatures.enumerated().filter { $0.offset != row }.map(\.element))
            reload(selecting: signatures.isEmpty ? nil : min(row, signatures.count - 1))
        }
    }

    @objc private func useChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        Preferences.setSignature(index > 0 ? signatures[index - 1] : nil, for: usePopups[sender.tag].use)
    }

    /// 이름·내용을 고칠 때마다 저장한다.
    private func commitEdits() {
        guard !isLoading, let row = selected else { return }
        let edited = Signature(id: signatures[row].id, name: nameField.stringValue, text: textView.string)
        save(signatures.enumerated().map { $0.offset == row ? edited : $0.element })
    }

    func controlTextDidChange(_ note: Notification) {
        commitEdits()
        guard let row = selected else { return }
        tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
        reloadUsePopups()
    }

    func textDidChange(_ notification: Notification) {
        commitEdits()
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        signatures.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView ?? Self.makeCell()
        cell.textField?.stringValue = signatures[row].name.isEmpty ? "이름 없음" : signatures[row].name
        return cell
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        cell.identifier = cellID
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        showSelection()
    }
}
