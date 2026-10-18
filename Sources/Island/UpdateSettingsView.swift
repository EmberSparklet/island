import AppKit
import IslandCore

/// Settings → Updates: the running and latest version, a one-click upgrade
/// when a newer release exists, `Check Now`, and the automatic-check switch.
/// State lives in `UpdateController`; this view mirrors it.
@MainActor
final class UpdateSettingsView: NSView {
    private let updates: UpdateController
    private let summary = NSTextField(labelWithString: "")
    private let upgradeButton = NSButton(title: "", target: nil, action: nil)
    private let checkButton = NSButton(
        title: L10n.current.text(.checkNow), target: nil, action: nil)
    private let autoToggle = NSButton(
        checkboxWithTitle: L10n.current.text(.checkAutomatically), target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")

    init(updates: UpdateController) {
        self.updates = updates
        super.init(frame: .zero)
        build()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let status = updates.status
        summary.stringValue = status.summary(current: updates.current)
        summary.textColor = status.needsAttention ? .systemRed : .labelColor
        let method = updates.method
        if case .available(let latest) = status {
            upgradeButton.title = method.buttonTitle(for: latest)
            upgradeButton.isHidden = false
        } else {
            upgradeButton.isHidden = true
        }
        checkButton.isEnabled = status != .checking
        autoToggle.state = updates.autoCheck ? .on : .off

        var lines: [String] = []
        if updates.lastUpgradeFailed {
            lines.append(L10n.current.text(.upgradeFailedLog))
        }
        switch method {
        case .brew:
            lines.append(L10n.current.formatted(.upgradeExplain, UpdateSource.cask))
        case .download:
            lines.append(L10n.current.formatted(.notHomebrew, UpdateSource.cask))
        }
        note.stringValue = lines.joined(separator: "\n")
    }

    private func build() {
        let title = NSTextField(labelWithString: L10n.current.text(.versionLabel))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        summary.font = .systemFont(ofSize: 13)
        upgradeButton.bezelColor = .controlAccentColor
        upgradeButton.keyEquivalent = "\r"
        upgradeButton.target = self
        upgradeButton.action = #selector(upgradeTapped)
        checkButton.target = self
        checkButton.action = #selector(checkTapped)
        autoToggle.target = self
        autoToggle.action = #selector(autoToggled)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [upgradeButton, checkButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, summary, buttons, autoToggle, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: buttons)
        stack.setCustomSpacing(14, after: autoToggle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
    }

    @objc private func upgradeTapped() {
        updates.upgrade()
    }

    @objc private func checkTapped() {
        updates.check(force: true)
    }

    @objc private func autoToggled() {
        updates.autoCheck = autoToggle.state == .on
    }
}
