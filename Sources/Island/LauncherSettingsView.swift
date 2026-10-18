import AppKit
import IslandCore

/// Settings → Launcher: one row per mode of the overlay's ring, in the order
/// `⇥` walks them, the first row being the mode the overlay opens in. A row
/// carries the mode's name, its kind, a checkbox per extra parameter and the
/// edit / delete actions; rows are reordered by dragging, and a sheet adds or
/// edits the site behind one of them.
///
/// Every judgement — validation, slug ids, the immutability of the task filter —
/// lives in `Launcher` (IslandCore): this view only mirrors the ring and reports
/// each change through `onChange`.
@MainActor
final class LauncherSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    /// Internal drag type, so only this table's own rows can be dropped back in.
    private static let rowType = NSPasteboard.PasteboardType("com.island.launcher-mode-row")
    private static let baseRowHeight: CGFloat = 34
    private static let optionRowHeight: CGFloat = 24
    private static let sheetWidth: CGFloat = 510
    private static let sheetLabelWidth: CGFloat = 110
    private static let sheetFieldWidth: CGFloat = 300

    private var modes: [LauncherMode]
    /// Which ring is actually in force. It cannot be recomputed from here — the
    /// environment and `ISLAND_LAUNCHER=off` have a say — so the host hands it
    /// back after every write.
    private var source: LauncherSettings.Source
    private let onChange: ([LauncherMode]) -> LauncherSettings.Source
    private let sourceLine = NSTextField(labelWithString: "")

    private let tableView = ModeTableView()
    private var tableHeight: NSLayoutConstraint?

    // Sheet state, non-nil only while the sheet is up.
    private var sheet: NSWindow?
    private var sheetNameField: NSTextField?
    private var sheetBaseURLField: NSTextField?
    private var sheetQueryItemField: NSTextField?
    private var sheetOptionStack: NSStackView?
    private var sheetOptionRows: [SheetOptionRow] = []
    private var sheetIssueLabel: NSTextField?
    private var sheetSaveButton: NSButton?
    private var sheetIssueCount = 0
    /// Last reading of the sheet's fields, kept so Save reuses it instead of
    /// collecting everything twice.
    private var sheetDraft = Launcher.Draft()
    private var sheetIssues: [Launcher.DraftIssue] = []
    /// The mode the sheet writes back, and the id an edit keeps. Both are `nil`
    /// while a mode being added is not valid yet.
    private var editingIndex: Int?
    private var editingID: String?

    init(
        modes: [LauncherMode], source: LauncherSettings.Source,
        onChange: @escaping ([LauncherMode]) -> LauncherSettings.Source
    ) {
        self.modes = modes
        self.source = source
        self.onChange = onChange
        super.init(frame: .zero)
        build()
        reload()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let footnote = NSTextField(
            wrappingLabelWithString: L10n.current.text(.launcherSettingsFootnote))
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        footnote.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(footnote)
        footnote.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        sourceLine.font = .systemFont(ofSize: 11)
        sourceLine.textColor = .tertiaryLabelColor
        sourceLine.translatesAutoresizingMaskIntoConstraints = false
        refreshSourceLine()
        stack.addArrangedSubview(sourceLine)
        stack.setCustomSpacing(12, after: sourceLine)

        configureTable()
        stack.addArrangedSubview(tableView)
        // The stack's own edge insets are not part of an arranged view's width.
        tableView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive =
            true
        stack.setCustomSpacing(12, after: tableView)

        let add = NSButton(
            title: L10n.current.text(.launcherAdd), target: self, action: #selector(addTapped))
        stack.addArrangedSubview(add)

        let document = LauncherDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = Self.baseRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableHeight = tableView.heightAnchor.constraint(equalToConstant: Self.baseRowHeight)
        tableHeight?.isActive = true
    }

    /// The whole page lives in one scroll view, so the table is laid out at its
    /// full height instead of scrolling inside a second scroller.
    private func reload() {
        tableView.reloadData()
        let total = modes.reduce(CGFloat.zero) { $0 + Self.rowHeight(for: $1) }
        tableHeight?.constant = max(total, Self.baseRowHeight)
    }

    private static func rowHeight(for mode: LauncherMode) -> CGFloat {
        baseRowHeight + CGFloat(mode.target?.options.count ?? 0) * optionRowHeight
    }

    private static func label(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        return label
    }

    /// A small pill, used for the default badge and for the mode's kind.
    private static func badge(_ text: String) -> NSView {
        let label = Self.label(text, size: 10, color: .secondaryLabelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = BadgeView()
        box.wantsLayer = true
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .horizontal)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        return box
    }

    private static func smallButton(
        _ title: String, target: AnyObject, action: Selector, identifier: String
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    /// A view that absorbs the spare width of a horizontal stack.
    private static func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return spacer
    }

    private static func sourceText(_ source: LauncherSettings.Source) -> String {
        switch source {
        case .off: L10n.current.text(.launcherSourceOff)
        case .settings: L10n.current.text(.launcherSourceSettings)
        case .environment: L10n.current.text(.launcherSourceEnvironment)
        case .builtIn: L10n.current.text(.launcherSourceBuiltIn)
        }
    }

    /// The line says where the live ring comes from, and a save moves it, so it
    /// is rewritten whenever the host reports a new source.
    private func refreshSourceLine() {
        sourceLine.stringValue = L10n.current.formatted(.launcherSource, Self.sourceText(source))
    }

    // MARK: - Rows

    private func rowView(for mode: LauncherMode, index: Int) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        if index == 0 { header.addArrangedSubview(Self.badge(L10n.current.text(.launcherDefault))) }

        let name = Self.label(mode.name, size: 13, color: .labelColor)
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(name)

        let kind =
            mode.isSearchTasks
            ? L10n.current.text(.searchTasks) : L10n.current.text(.launcherKindWeb)
        header.addArrangedSubview(Self.badge(kind))
        header.addArrangedSubview(Self.flexibleSpacer())
        // The task filter is neither editable nor removable — the model refuses
        // both — so the row shows no action at all.
        if let target = mode.target {
            header.addArrangedSubview(
                Self.smallButton(
                    L10n.current.text(.launcherEdit), target: self,
                    action: #selector(editTapped(_:)),
                    identifier: target.id))
            header.addArrangedSubview(
                Self.smallButton(
                    L10n.current.text(.launcherDelete), target: self,
                    action: #selector(deleteTapped(_:)), identifier: target.id))
        }
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for (optionIndex, option) in (mode.target?.options ?? []).enumerated() {
            let box = NSButton(
                checkboxWithTitle: option.label.isEmpty ? option.key : option.label, target: self,
                action: #selector(optionToggled(_:)))
            box.state = option.isEnabled ? .on : .off
            box.controlSize = .small
            box.font = .systemFont(ofSize: 11)
            box.identifier = NSUserInterfaceItemIdentifier(mode.target?.id ?? "")
            box.tag = optionIndex
            stack.addArrangedSubview(box)
        }
        return stack
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { modes.count }

    /// A row grows with the checkboxes it carries, and the table is then given
    /// exactly the sum of those heights.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        modes.indices.contains(row) ? Self.rowHeight(for: modes[row]) : Self.baseRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard modes.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let content = rowView(for: modes[row], index: row)
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> NSPasteboardWriting?
    {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        // The ring is a list: only an insertion between rows reorders it, and
        // only this table's own rows may be dropped back in.
        guard (info.draggingSource as? NSTableView) === tableView, dropOperation == .above
        else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard
            let text = info.draggingPasteboard.pasteboardItems?.first?.string(
                forType: Self.rowType),
            let from = Int(text)
        else { return false }
        // `row` is the insertion index before the moved row is taken out, which
        // is exactly what `Launcher.moving` expects.
        let moved = Launcher.moving(modes, from: from, to: row)
        guard moved != modes else { return false }
        modes = Launcher.sanitized(moved)
        reload()
        source = onChange(modes)
        refreshSourceLine()
        return true
    }

    // MARK: - Row actions

    @objc private func optionToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let index = modes.firstIndex(where: { $0.target?.id == id }),
            var target = modes[index].target, target.options.indices.contains(sender.tag)
        else { return }
        target.options[sender.tag].isEnabled = sender.state == .on
        modes = Launcher.sanitized(Launcher.replacing(modes, at: index, with: .target(target)))
        source = onChange(modes)
        refreshSourceLine()
    }

    @objc private func editTapped(_ sender: NSButton) {
        openSheet(for: sender.identifier?.rawValue)
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard modes.indices.contains(row) else { return }
        openSheet(for: modes[row].target?.id)
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let index = modes.firstIndex(where: { $0.target?.id == id })
        else { return }
        modes = Launcher.sanitized(Launcher.removing(modes, at: index))
        reload()
        source = onChange(modes)
        refreshSourceLine()
    }

    @objc private func addTapped() {
        // A new site starts with the parameter that made DeepSeek's deep link
        // work, left unticked: a question only sends once the user says so.
        var draft = Launcher.Draft()
        draft.options = [
            LauncherOption(
                key: "autosend", value: "1", label: L10n.current.text(.launcherOptionAutoSend))
        ]
        openSheet(draft: draft, index: nil, id: nil)
    }

    private func openSheet(for id: String?) {
        guard sheet == nil, let id, let index = modes.firstIndex(where: { $0.target?.id == id }),
            let target = modes[index].target
        else { return }
        openSheet(draft: Launcher.Draft(target), index: index, id: target.id)
    }

    private func openSheet(draft: Launcher.Draft, index: Int?, id: String?) {
        guard sheet == nil else { return }
        editingIndex = index
        editingID = id
        sheetIssueCount = 0
        let window = makeSheetWindow(draft: draft, isEdit: index != nil)
        sheet = window
        validateSheet()
        if let host = self.window {
            host.beginSheet(window)
        } else {
            NSApp.runModal(for: window)
        }
    }

    // MARK: - The add / edit sheet

    private func makeSheetWindow(draft: Launcher.Draft, isEdit: Bool) -> NSWindow {
        let titleKey: TextKey = isEdit ? .launcherSheetEdit : .launcherSheetAdd
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: L10n.current.text(titleKey))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(14, after: heading)

        let nameField = NSTextField(string: draft.name)
        let baseURLField = NSTextField(string: draft.baseURLText)
        baseURLField.placeholderString = "https://www.example.com/"
        let queryItemField = NSTextField(string: draft.queryItem)
        queryItemField.placeholderString = "q"
        let fields: [(TextKey, NSTextField)] = [
            (.launcherFieldName, nameField),
            (.launcherFieldBaseURL, baseURLField),
            (.launcherFieldQueryItem, queryItemField),
        ]
        for (key, field) in fields {
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: Self.sheetFieldWidth).isActive = true
            stack.addArrangedSubview(Self.fieldRow(L10n.current.text(key), field))
        }
        sheetNameField = nameField
        sheetBaseURLField = baseURLField
        sheetQueryItemField = queryItemField
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }

        stack.addArrangedSubview(Self.optionHeader())
        let optionStack = NSStackView()
        optionStack.orientation = .vertical
        optionStack.alignment = .leading
        optionStack.spacing = 6
        optionStack.translatesAutoresizingMaskIntoConstraints = false
        sheetOptionStack = optionStack
        stack.addArrangedSubview(optionStack)
        for option in draft.options { appendOptionRow(option) }

        let addOption = NSButton(
            title: L10n.current.text(.launcherOptionAdd), target: self,
            action: #selector(addOptionTapped))
        stack.addArrangedSubview(addOption)
        stack.setCustomSpacing(14, after: addOption)

        // Everything the draft got wrong, instead of dropping the input.
        let issues = NSTextField(wrappingLabelWithString: "")
        issues.font = .systemFont(ofSize: 11)
        issues.textColor = .systemRed
        issues.isHidden = true
        issues.translatesAutoresizingMaskIntoConstraints = false
        issues.widthAnchor.constraint(equalToConstant: Self.sheetWidth - 40).isActive = true
        sheetIssueLabel = issues
        stack.addArrangedSubview(issues)

        let cancel = NSButton(
            title: L10n.current.text(.launcherCancel), target: self, action: #selector(cancelTapped)
        )
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(
            title: L10n.current.text(.launcherSave), target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        sheetSaveButton = save
        let buttons = NSStackView(views: [Self.flexibleSpacer(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L10n.current.text(titleKey)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        return window
    }

    private static func fieldRow(_ title: String, _ field: NSView) -> NSStackView {
        let label = Self.label(title, size: 12, color: .labelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: sheetLabelWidth).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Column titles for the parameter list, aligned with `SheetOptionRow`.
    private static func optionHeader() -> NSStackView {
        let row = NSStackView(views: [
            Self.columnLabel(L10n.current.text(.launcherFieldOptionKey), width: SheetMetrics.key),
            Self.columnLabel(
                L10n.current.text(.launcherFieldOptionValue), width: SheetMetrics.value),
            Self.columnLabel(
                L10n.current.text(.launcherFieldOptionLabel), width: SheetMetrics.label),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private static func columnLabel(_ title: String, width: CGFloat) -> NSTextField {
        let label = Self.label(title, size: 11, color: .secondaryLabelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func appendOptionRow(_ option: LauncherOption) {
        let row = SheetOptionRow(option: option)
        for field in [row.keyField, row.valueField, row.labelField] { field.delegate = self }
        row.enabledBox.target = self
        row.enabledBox.action = #selector(optionEnableToggled(_:))
        row.removeButton.target = self
        row.removeButton.action = #selector(removeOptionTapped(_:))
        sheetOptionRows.append(row)
        sheetOptionStack?.addArrangedSubview(row.stack)
    }

    private func collectDraft() -> Launcher.Draft {
        Launcher.Draft(
            name: sheetNameField?.stringValue ?? "",
            baseURLText: sheetBaseURLField?.stringValue ?? "",
            queryItem: sheetQueryItemField?.stringValue ?? "",
            options: sheetOptionRows.map {
                LauncherOption(
                    key: $0.keyField.stringValue, value: $0.valueField.stringValue,
                    label: $0.labelField.stringValue, isEnabled: $0.enabledBox.state == .on)
            })
    }

    private func showIssues(_ issues: [Launcher.DraftIssue]) {
        sheetIssueLabel?.stringValue =
            issues.map { L10n.current.text($0.textKey) }.joined(separator: "\n")
        sheetIssueLabel?.isHidden = issues.isEmpty
        sheetSaveButton?.isEnabled = issues.isEmpty
        // The error list is part of the sheet's height, so the window grows and
        // shrinks with it instead of clipping the text.
        if issues.count != sheetIssueCount {
            sheetIssueCount = issues.count
            resizeSheet()
        }
    }

    /// Reads the fields, shows every issue and enables Save only for a clean
    /// draft. The result is cached for `saveTapped`, and nothing is written back
    /// here: the ring changes on Save alone, so Cancel always drops the edit.
    private func validateSheet() {
        guard sheet != nil else { return }
        sheetDraft = collectDraft()
        sheetIssues = Launcher.issues(in: sheetDraft)
        showIssues(sheetIssues)
    }

    private func resizeSheet() {
        guard let window = sheet, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    private func closeSheet() {
        guard let window = sheet else { return }
        if let host = window.sheetParent {
            host.endSheet(window)
        } else {
            NSApp.stopModal()
            window.orderOut(nil)
        }
        sheet = nil
        sheetNameField = nil
        sheetBaseURLField = nil
        sheetQueryItemField = nil
        sheetOptionStack = nil
        sheetOptionRows = []
        sheetIssueLabel = nil
        sheetSaveButton = nil
        sheetIssueCount = 0
        sheetDraft = Launcher.Draft()
        sheetIssues = []
        editingIndex = nil
        editingID = nil
    }

    @objc private func addOptionTapped() {
        appendOptionRow(LauncherOption(key: "", value: "", label: ""))
        resizeSheet()
        validateSheet()
    }

    @objc private func removeOptionTapped(_ sender: NSButton) {
        guard let index = sheetOptionRows.firstIndex(where: { $0.removeButton === sender }) else {
            return
        }
        let row = sheetOptionRows.remove(at: index)
        sheetOptionStack?.removeArrangedSubview(row.stack)
        row.stack.removeFromSuperview()
        resizeSheet()
        validateSheet()
    }

    @objc private func optionEnableToggled(_ sender: NSButton) {
        validateSheet()
    }

    /// The only path that touches the ring. A draft with issues is neither
    /// written back nor able to close the sheet.
    @objc private func saveTapped() {
        validateSheet()
        guard sheetIssues.isEmpty else { return }
        let taken = Set(
            modes.enumerated().filter { $0.offset != editingIndex }
                .compactMap { $0.element.target?.id })
        guard
            let target = Launcher.target(
                from: sheetDraft, keepingID: editingID, taken: taken)
        else { return }
        var next = modes
        if let index = editingIndex, next.indices.contains(index) {
            next = Launcher.replacing(next, at: index, with: .target(target))
        } else {
            next = Launcher.inserting(next, .target(target), at: next.count)
        }
        modes = Launcher.sanitized(next)
        reload()
        source = onChange(modes)
        refreshSourceLine()
        closeSheet()
    }

    @objc private func cancelTapped() {
        closeSheet()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        validateSheet()
    }

}

/// A table whose single column is always exactly as wide as the table itself.
///
/// `NSTableView` sizes a column to the width the table had when the column was
/// added; this table is created before Auto Layout gives it its real (inset)
/// width, so the column stayed ~40pt wider and the rows drew past the right
/// edge — `Delete` came out half cut off.
private final class ModeTableView: NSTableView {
    override func layout() {
        super.layout()
        guard let column = tableColumns.first, column.width != bounds.width else { return }
        column.width = bounds.width
    }
}

/// Widths shared by the parameter header and its rows.
private enum SheetMetrics {
    static let key: CGFloat = 100
    static let value: CGFloat = 90
    static let label: CGFloat = 110
    static let remove: CGFloat = 56
}

/// One row of the sheet's parameter list — a dumb container whose fields and
/// buttons the view wires up.
@MainActor
private final class SheetOptionRow {
    let stack = NSStackView()
    let keyField: NSTextField
    let valueField: NSTextField
    let labelField: NSTextField
    let enabledBox: NSButton
    let removeButton: NSButton

    init(option: LauncherOption) {
        keyField = NSTextField(string: option.key)
        valueField = NSTextField(string: option.value)
        labelField = NSTextField(string: option.label)
        enabledBox = NSButton(
            checkboxWithTitle: L10n.current.text(.launcherFieldOptionEnabled), target: nil,
            action: nil)
        enabledBox.state = option.isEnabled ? .on : .off
        removeButton = NSButton(
            title: L10n.current.text(.launcherDelete), target: nil, action: nil)

        let widths: [(NSTextField, CGFloat)] = [
            (keyField, SheetMetrics.key),
            (valueField, SheetMetrics.value),
            (labelField, SheetMetrics.label),
        ]
        for (field, width) in widths {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        for button in [enabledBox, removeButton] {
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        removeButton.widthAnchor.constraint(equalToConstant: SheetMetrics.remove).isActive = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(keyField)
        stack.addArrangedSubview(valueField)
        stack.addArrangedSubview(labelField)
        stack.addArrangedSubview(enabledBox)
        stack.addArrangedSubview(removeButton)
    }
}

/// Top-left origin, so a short document sits at the top of its scroll view.
private final class LauncherDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A pill whose background is resolved per drawing, so light and dark mode each
/// get the right grey.
private final class BadgeView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 4
    }
}
