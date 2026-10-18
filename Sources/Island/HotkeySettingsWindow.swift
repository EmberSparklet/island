import AppKit
import IslandCore

/// The settings window behind the menu's `Settings…` item, one tab per topic:
/// General (record the summon hotkey by pressing it, switch it on or off, or
/// clear it — PLAN § Scope #3, #5), Appearance (overlay theme, keyboard
/// hints), Notifications (the pop-up shown when a run finishes), Agents
/// (which agent scenarios island watches, see `AgentSettingsView`), Updates
/// (`UpdateSettingsView`, its label dotted while an upgrade waits) and
/// Feedback (`FeedbackSettingsView`).
///
/// It is a regular, key-capable window — unlike the overlay — because the user
/// has to be able to press keys into it.
@MainActor
final class HotkeySettingsWindow: NSObject, NSTextFieldDelegate {
    private let coordinator: HotkeySettingsCoordinator
    private let onHotkeyChanged: (HotkeySpec, Bool) -> Void
    private let onThemeChanged: (OverlayTheme) -> Void
    private let themePicker = NSPopUpButton()
    private let languagePicker = NSPopUpButton()
    private let onLanguageChanged: (AppLanguage) -> Void
    private let onHintsChanged: (Bool) -> Void
    private let hintsToggle = NSButton(
        checkboxWithTitle: L10n.current.text(.showKeyboardHints), target: nil, action: nil)
    private let onPopupChanged: (PopupSettings) -> Void
    private var popup: PopupSettings
    private let popupToggle = NSButton(
        checkboxWithTitle: L10n.current.text(.popupOnFinish), target: nil, action: nil)
    private let popupSeconds = NSTextField(string: "")
    private let agentsView: AgentSettingsView
    private let launcherView: LauncherSettingsView
    private let onLauncherChanged: ([LauncherMode]) -> LauncherSettings.Source
    private let updates: UpdateController
    private let updatesView: UpdateSettingsView
    private let feedbackView: FeedbackSettingsView
    private let tabs = NSTabView()
    private let updatesTab = NSTabViewItem(identifier: "Updates")
    private let window: SettingsWindow
    private let recorder: HotkeyRecorderView
    private let enabledToggle: NSButton
    private let feedback: NSTextField

    init(
        coordinator: HotkeySettingsCoordinator,
        theme: OverlayTheme,
        language: AppLanguage,
        showsHints: Bool,
        popup: PopupSettings,
        scenarios: AgentScenarioSettings,
        launcherModes: [LauncherMode],
        launcherSource: LauncherSettings.Source,
        updates: UpdateController,
        feedbackEnvironment: FeedbackEnvironment,
        onHotkeyChanged: @escaping (HotkeySpec, Bool) -> Void,
        onThemeChanged: @escaping (OverlayTheme) -> Void,
        onLanguageChanged: @escaping (AppLanguage) -> Void,
        onHintsChanged: @escaping (Bool) -> Void,
        onPopupChanged: @escaping (PopupSettings) -> Void,
        onScenariosChanged: @escaping (AgentScenarioSettings) -> Void,
        onLauncherChanged: @escaping ([LauncherMode]) -> LauncherSettings.Source
    ) {
        self.popup = popup
        self.onPopupChanged = onPopupChanged
        self.onLanguageChanged = onLanguageChanged
        self.onHintsChanged = onHintsChanged
        self.coordinator = coordinator
        self.onHotkeyChanged = onHotkeyChanged
        self.onThemeChanged = onThemeChanged
        recorder = HotkeyRecorderView()
        enabledToggle = NSButton(
            checkboxWithTitle: L10n.current.text(.enabled), target: nil, action: nil)
        feedback = NSTextField(labelWithString: "")
        agentsView = AgentSettingsView(settings: scenarios, onChange: onScenariosChanged)
        launcherView = LauncherSettingsView(
            modes: launcherModes, source: launcherSource, onChange: onLauncherChanged)
        self.onLauncherChanged = onLauncherChanged
        self.updates = updates
        updatesView = UpdateSettingsView(updates: updates)
        feedbackView = FeedbackSettingsView(environment: feedbackEnvironment)
        window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = L10n.current.text(.settingsTitle)
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView()

        recorder.onRecord = { [weak self] spec in
            self?.recorderDidRecord(spec)
        }
        recorder.onReject = { [weak self] in
            self?.recorderDidReject()
        }
        recorder.onCancel = { [weak self] in
            self?.refreshFromCoordinator()
        }
        enabledToggle.target = self
        enabledToggle.action = #selector(enabledToggled)
        themePicker.addItems(withTitles: OverlayTheme.allCases.map(\.displayName))
        themePicker.selectItem(at: OverlayTheme.allCases.firstIndex(of: theme) ?? 0)
        themePicker.target = self
        themePicker.action = #selector(themePicked)
        languagePicker.addItems(withTitles: AppLanguage.allCases.map(\.label))
        languagePicker.selectItem(at: AppLanguage.allCases.firstIndex(of: language) ?? 0)
        languagePicker.target = self
        languagePicker.action = #selector(languagePicked)
        hintsToggle.state = showsHints ? .on : .off
        hintsToggle.target = self
        hintsToggle.action = #selector(hintsToggled)
        popupToggle.target = self
        popupToggle.action = #selector(popupToggled)
        popupSeconds.delegate = self
        refreshPopup()
        refreshFromCoordinator()
    }

    /// `tab` is a tab identifier (its untitled label, e.g. "Updates").
    func show(tab: String? = nil) {
        refreshFromCoordinator()
        if let tab { tabs.selectTabViewItem(withIdentifier: tab) }
        // Opening settings is a natural moment to look for a release.
        updates.check()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Nothing focused: recording starts only when the field is clicked.
        window.makeFirstResponder(nil)
    }

    /// The delegate rebuilds this object on a language change and puts the
    /// window back exactly as it found it.
    var isVisible: Bool { window.isVisible }

    func close() {
        window.close()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        tabs.translatesAutoresizingMaskIntoConstraints = false
        // Identifiers stay English: `show(tab:)` matches on them.
        for (id, label, view) in [
            ("General", L10n.current.text(.tabGeneral), pane(generalSection())),
            ("Appearance", L10n.current.text(.tabAppearance), pane(appearanceSection())),
            ("Notifications", L10n.current.text(.tabNotifications), pane(notificationSection())),
            ("Agents", L10n.current.text(.tabAgents), agentsView as NSView),
            ("Launcher", L10n.current.text(.tabLauncher), launcherView as NSView),
        ] {
            let item = NSTabViewItem(identifier: id)
            item.label = label
            item.view = view
            tabs.addTabViewItem(item)
        }
        updatesTab.view = updatesView
        tabs.addTabViewItem(updatesTab)
        let feedbackTab = NSTabViewItem(identifier: "Feedback")
        feedbackTab.label = L10n.current.text(.tabFeedback)
        feedbackTab.view = feedbackView
        tabs.addTabViewItem(feedbackTab)
        updateStatusChanged()

        let content = NSView()
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        return content
    }

    /// A tab's contents, pinned to its top edge.
    private func pane(_ stack: NSStackView) -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
        ])
        return view
    }

    private func generalSection() -> NSStackView {
        let localizer = L10n.current
        let title = label(
            localizer.text(.summonHotkeyTitle), font: .systemFont(ofSize: 13, weight: .semibold))
        recorder.translatesAutoresizingMaskIntoConstraints = false

        let help = label(
            localizer.text(.recordHelp),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        feedback.font = .systemFont(ofSize: 11)
        feedback.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(
            title: localizer.text(.clearButton), target: self, action: #selector(clearTapped))
        let reset = NSButton(
            title: localizer.text(.resetToDefault), target: self, action: #selector(resetTapped))
        let apply = NSButton(
            title: localizer.text(.applyButton), target: self, action: #selector(applyTapped))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [clear, reset, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, recorder, help, enabledToggle, feedback, buttons])
        NSLayoutConstraint.activate([
            recorder.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recorder.heightAnchor.constraint(equalToConstant: 44),
        ])
        return stack
    }

    private func appearanceSection() -> NSStackView {
        let localizer = L10n.current
        let themeTitle = label(
            localizer.text(.overlayThemeTitle), font: .systemFont(ofSize: 13, weight: .semibold))
        let themeHelp = label(
            localizer.text(.themeHelp),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        let languageTitle = label(
            localizer.text(.languageTitle), font: .systemFont(ofSize: 13, weight: .semibold))
        let languageHelp = label(
            localizer.text(.languageHelp),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        let stack = NSStackView(views: [
            themeTitle, themePicker, themeHelp, hintsToggle, languageTitle, languagePicker,
            languageHelp,
        ])
        stack.setCustomSpacing(20, after: themeHelp)
        return stack
    }

    private func notificationSection() -> NSStackView {
        let localizer = L10n.current
        let popupTitle = label(
            localizer.text(.popupTitle), font: .systemFont(ofSize: 13, weight: .semibold))
        popupSeconds.alignment = .right
        popupSeconds.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let secondsRow = NSStackView(views: [
            label(localizer.text(.stayOnScreenFor), font: .systemFont(ofSize: 13)), popupSeconds,
            label(localizer.text(.secondsUnit), font: .systemFont(ofSize: 13)),
        ])
        secondsRow.orientation = .horizontal
        secondsRow.spacing = 6
        let popupHelp = label(
            localizer.text(.popupHelp),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        return NSStackView(views: [popupTitle, popupToggle, secondsRow, popupHelp])
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }

    // MARK: - State

    /// Mirrors `UpdateController.status` into the Updates tab and its label.
    func updateStatusChanged() {
        updatesTab.label = updates.status.tabLabel
        updatesView.refresh()
    }

    /// Pushes the coordinator's state into the controls; never notifies back.
    private func refreshFromCoordinator() {
        recorder.setSpec(coordinator.current)
        enabledToggle.state = coordinator.isEnabled ? .on : .off
        if coordinator.isEnabled {
            feedback.textColor = .secondaryLabelColor
            feedback.stringValue = L10n.current.formatted(
                .hintActive, coordinator.current.displayString)
        } else {
            feedback.textColor = .secondaryLabelColor
            feedback.stringValue = L10n.current.text(.hintHotkeyOffApply)
        }
    }

    private func refreshPopup() {
        popupToggle.state = popup.isEnabled ? .on : .off
        popupSeconds.stringValue = ResolvedConfiguration.secondsText(popup.seconds)
        popupSeconds.isEnabled = popup.isEnabled
    }

    // MARK: - Actions

    @objc private func popupToggled() {
        popup.isEnabled = popupToggle.state == .on
        refreshPopup()
        onPopupChanged(popup)
    }

    /// Saves every usable value as it is typed: Return belongs to `Apply`, so
    /// the field cannot wait for it.
    func controlTextDidChange(_ notification: Notification) {
        guard let seconds = PopupSettings.seconds(from: popupSeconds.stringValue),
            seconds != popup.seconds
        else { return }
        popup.seconds = seconds
        onPopupChanged(popup)
    }

    /// Leaving the field with an unusable value snaps it back.
    func controlTextDidEndEditing(_ notification: Notification) {
        refreshPopup()
    }

    private func recorderDidRecord(_ spec: HotkeySpec) {
        feedback.textColor = .secondaryLabelColor
        feedback.stringValue = L10n.current.formatted(.hintPressApply, spec.displayString)
    }

    private func recorderDidReject() {
        showFailure(L10n.current.text(.failNeedsModifier))
    }

    @objc private func applyTapped() {
        guard let spec = recorder.spec else {
            showFailure(L10n.current.text(.failPressComboFirst))
            return
        }

        // While off, `apply` only remembers the key; switch on afterwards so a
        // refused registration cannot lose the recording.
        switch coordinator.apply(spec.specText) {
        case .invalidText(let error):
            showFailure(describe(error))
        case .registrationFailed(let reason):
            showFailure(
                L10n.current.formatted(
                    .failRefusedKept, reason, coordinator.current.displayString))
        case .applied(let applied):
            if coordinator.isEnabled {
                reportSuccess(applied)
            } else {
                enable(with: applied)
            }
        }
    }

    private func enable(with spec: HotkeySpec) {
        switch coordinator.setEnabled(true) {
        case .enabled:
            reportSuccess(spec)
        case .registrationFailed(let reason):
            showFailure(L10n.current.formatted(.failRefusedStaysOff, reason))
            refreshFromCoordinator()
        case .disabled:
            break
        }
    }

    @objc private func clearTapped() {
        if coordinator.isEnabled {
            _ = coordinator.setEnabled(false)
        }
        recorder.setSpec(nil)
        enabledToggle.state = .off
        feedback.textColor = .secondaryLabelColor
        feedback.stringValue = L10n.current.text(.hintSwitchedOffFree)
        onHotkeyChanged(coordinator.current, false)
    }

    @objc private func resetTapped() {
        recorder.setSpec(HotkeyConfiguration.fallbackSpec)
        applyTapped()
    }

    /// The `↑↓ move · ↩ open …` footer shown while typing in the overlay.
    @objc private func hintsToggled() {
        onHintsChanged(hintsToggle.state == .on)
    }

    @objc private func themePicked() {
        let index = themePicker.indexOfSelectedItem
        guard OverlayTheme.allCases.indices.contains(index) else { return }
        onThemeChanged(OverlayTheme.allCases[index])
    }

    /// The whole window is rebuilt by the app delegate, so this only reports.
    @objc private func languagePicked() {
        let index = languagePicker.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(index) else { return }
        onLanguageChanged(AppLanguage.allCases[index])
    }

    @objc private func enabledToggled() {
        let shouldEnable = enabledToggle.state == .on
        switch coordinator.setEnabled(shouldEnable) {
        case .enabled(let spec):
            reportSuccess(spec)
        case .disabled:
            feedback.textColor = .secondaryLabelColor
            feedback.stringValue = L10n.current.text(.hintSwitchedOff)
            onHotkeyChanged(coordinator.current, false)
        case .registrationFailed(let reason):
            showFailure(L10n.current.formatted(.failRefusedStaysOff, reason))
            refreshFromCoordinator()
        }
    }

    private func reportSuccess(_ spec: HotkeySpec) {
        recorder.setSpec(spec)
        enabledToggle.state = .on
        feedback.textColor = .secondaryLabelColor
        feedback.stringValue = L10n.current.formatted(.hintSaved, spec.displayString)
        onHotkeyChanged(spec, true)
    }

    private func showFailure(_ message: String) {
        feedback.textColor = .systemRed
        feedback.stringValue = message
    }

    private func describe(_ error: HotkeySpecError) -> String {
        switch error {
        case .empty: return L10n.current.text(.errorEmpty)
        case .missingModifier: return L10n.current.text(.errorMissingModifier)
        case .unknownModifier(let name):
            return L10n.current.formatted(.errorUnknownModifier, name)
        case .unknownKey(let name): return L10n.current.formatted(.errorUnknownKey, name)
        }
    }
}

/// island is an accessory app with no main menu, so nothing routes ⌘W to the
/// window; this handles ⌘W and Esc itself (see `SettingsKey`). The recorder
/// gets the keys first while it is recording.
@MainActor
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return closeIfAsked(by: event)
    }

    /// Esc (or ⌘W) that no control consumed — e.g. nothing is focused.
    override func keyDown(with event: NSEvent) {
        if !closeIfAsked(by: event) { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    private func closeIfAsked(by event: NSEvent) -> Bool {
        let action = SettingsKey.action(
            isRecording: false,
            keyCode: UInt32(event.keyCode),
            modifiers: HotkeyRecorderView.modifiers(from: event.modifierFlags)
        )
        guard action == .closeWindow else { return false }
        performClose(nil)
        return true
    }
}
