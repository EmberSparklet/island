import AppKit
import IslandCore

/// Settings → Launcher: one row per mode of the overlay's ring, in the order
/// `⇥` walks them. A row carries the mode's name, its kind, an ⓘ behind the
/// sites island measured by hand, the edit / delete actions and a tick box that
/// decides whether `⇥` stops there at all; rows are reordered by dragging, and a
/// sheet adds or edits the site behind one of them.
///
/// The list scrolls inside its own region, and `Add mode…` sits in a bar below
/// it, so the button never moves with the content.
///
/// Every judgement — validation, slug ids, where the overlay lands, the
/// immutability of the task filter — lives in `Launcher` (IslandCore): this view
/// only mirrors the ring and reports each change through `onChange`, which hands
/// back the source that is actually in force.
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
    /// The ⓘ is a fixed square, which keeps the footnote's wrap width fixed too.
    private static let infoButtonSize: CGFloat = 16
    private static let popoverWidth: CGFloat = 320

    private var modes: [LauncherMode]
    /// Which ring is actually in force. It cannot be recomputed from here — the
    /// environment and `ISLAND_LAUNCHER=off` have a say — so the host hands it
    /// back after every write.
    private var source: LauncherSettings.Source
    private let onChange: ([LauncherMode]) -> LauncherSettings.Source
    private let sourceLine = NSTextField(labelWithString: "")

    private let tableView = ModeTableView()
    private var tableHeight: NSLayoutConstraint?
    /// The ⓘ note on screen, kept so a reload can dismiss it.
    private var popover: NSPopover?

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
        // Top: one line of what this tab is, with the page's own ⓘ, then where
        // the live ring comes from.
        let footnote = NSTextField(
            wrappingLabelWithString: L10n.current.text(.launcherSettingsFootnote))
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        footnote.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footnote)

        let pageInfo = Self.infoButton(target: self, action: #selector(howToTapped(_:)))
        pageInfo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageInfo)

        sourceLine.font = .systemFont(ofSize: 11)
        sourceLine.textColor = .tertiaryLabelColor
        sourceLine.translatesAutoresizingMaskIntoConstraints = false
        refreshSourceLine()
        addSubview(sourceLine)

        // Middle: the only region that scrolls. The table keeps its `tableHeight`
        // constraint, which is what makes the rows scroll inside this clip view.
        configureTable()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // Bottom: a bar that stays put while the list scrolls.
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(
            title: L10n.current.text(.launcherAdd), target: self, action: #selector(addTapped))
        add.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(separator)
        bar.addSubview(add)
        addSubview(bar)

        NSLayoutConstraint.activate([
            footnote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            footnote.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            footnote.widthAnchor.constraint(
                equalTo: widthAnchor, constant: -40 - Self.infoButtonSize - 6),
            pageInfo.leadingAnchor.constraint(equalTo: footnote.trailingAnchor, constant: 6),
            pageInfo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            pageInfo.firstBaselineAnchor.constraint(equalTo: footnote.firstBaselineAnchor),
            pageInfo.widthAnchor.constraint(equalToConstant: Self.infoButtonSize),
            pageInfo.heightAnchor.constraint(equalToConstant: Self.infoButtonSize),

            sourceLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            sourceLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            sourceLine.topAnchor.constraint(equalTo: footnote.bottomAnchor, constant: 6),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: sourceLine.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),

            tableView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            tableView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            tableView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.topAnchor),
            add.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            add.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            add.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12),
        ])
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
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

    /// The rows are laid out at their full height, so the scroll region above the
    /// bar is what moves, not the bar.
    private func reload() {
        popover?.close()
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

    /// The ⓘ used both for the page's `how to` note and for a mode's own note.
    private static func infoButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
                ?? NSImage(),
            target: target, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = L10n.current.text(.launcherInfo)
        button.setAccessibilityLabel(L10n.current.text(.launcherInfo))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        // The badge follows the landing spot, not the top of the list: a row
        // nobody ticked is not where a summon goes.
        if index == Launcher.summonIndex(in: modes) {
            header.addArrangedSubview(Self.badge(L10n.current.text(.launcherDefault)))
        }

        let name = Self.label(mode.name, size: 13, color: .labelColor)
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(name)

        // Only the sites island measured by hand have a note to show.
        if let target = mode.target, Launcher.detail(for: target) != nil {
            let info = Self.infoButton(target: self, action: #selector(detailTapped(_:)))
            info.identifier = NSUserInterfaceItemIdentifier(target.id)
            header.addArrangedSubview(info)
        }

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

        // The row's last control: whether `⇥` stops here. The task filter is
        // island's own function, so its box is on and cannot be clicked.
        let enabled = NSButton(
            checkboxWithTitle: L10n.current.text(.launcherFieldOptionEnabled), target: self,
            action: #selector(enabledToggled(_:)))
        enabled.state = mode.isEnabled ? .on : .off
        enabled.controlSize = .small
        enabled.font = .systemFont(ofSize: 11)
        enabled.tag = index
        if mode.isSearchTasks {
            enabled.isEnabled = false
            enabled.toolTip = L10n.current.text(.launcherAlwaysOn)
        }
        header.addArrangedSubview(enabled)

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
        commit(moved)
        return true
    }

    // MARK: - Row actions

    /// Hands a new ring to the host and mirrors what comes back: only the host
    /// knows which source is in force once the saved list changed.
    private func commit(_ updated: [LauncherMode]) {
        modes = Launcher.sanitized(updated)
        source = onChange(modes)
        refreshSourceLine()
        reload()
    }

    @objc private func enabledToggled(_ sender: NSButton) {
        let toggled = Launcher.settingEnabled(sender.state == .on, at: sender.tag, in: modes)
        guard toggled != modes else { return }
        commit(toggled)
    }

    @objc private func optionToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let index = modes.firstIndex(where: { $0.target?.id == id }),
            var target = modes[index].target, target.options.indices.contains(sender.tag)
        else { return }
        target.options[sender.tag].isEnabled = sender.state == .on
        commit(Launcher.replacing(modes, at: index, with: .target(target)))
    }

    @objc private func editTapped(_ sender: NSButton) {
        openSheet(for: sender.identifier?.rawValue)
    }

    @objc private func detailTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let target = modes.compactMap(\.target).first(where: { $0.id == id }),
            let detail = Launcher.detail(for: target)
        else { return }
        showPopover(detail, from: sender)
    }

    @objc private func howToTapped(_ sender: NSButton) {
        showPopover(L10n.current.text(.launcherHowTo), from: sender)
    }

    /// One line of text under the button that was clicked.
    private func showPopover(_ text: String, from anchor: NSView) {
        popover?.close()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = Self.popoverWidth - 24
        label.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(label)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
        ])
        let controller = NSViewController()
        controller.view = host
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        self.popover = popover
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
        commit(Launcher.removing(modes, at: index))
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
            },
            // The tick box belongs to the row, not to this sheet, so the draft
            // carries the mode's own value through instead of inventing one.
            isEnabled: editingIsEnabled)
    }

    /// Whether the mode behind the sheet is ticked. A mode being added is.
    private var editingIsEnabled: Bool {
        editingIndex.flatMap { modes.indices.contains($0) ? modes[$0].isEnabled : nil } ?? true
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
        commit(next)
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

/// A pill whose background is resolved per drawing, so light and dark mode each
/// get the right grey.
private final class BadgeView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 4
    }
}
