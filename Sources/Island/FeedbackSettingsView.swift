import AppKit
import IslandCore

/// Settings → Feedback: type a message, then send it through the user's own
/// mail client, as a prefilled GitHub issue, or copy it. There is no server;
/// `FeedbackReport` (IslandCore) builds every channel.
@MainActor
final class FeedbackSettingsView: NSView {
    private let environment: FeedbackEnvironment
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "")

    init(environment: FeedbackEnvironment) {
        self.environment = environment
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let title = NSTextField(labelWithString: L10n.current.text(.sendFeedback))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let help = NSTextField(
            labelWithString: L10n.current.text(.feedbackIntro))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let mail = NSButton(
            title: L10n.current.text(.sendEmail), target: self, action: #selector(mailTapped))
        mail.keyEquivalent = "\r"
        mail.keyEquivalentModifierMask = [.command]
        let issue = NSButton(
            title: L10n.current.text(.openGitHubIssue), target: self, action: #selector(issueTapped)
        )
        let copy = NSButton(
            title: L10n.current.text(.copyButton), target: self, action: #selector(copyTapped))
        let buttons = NSStackView(views: [mail, issue, copy])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, help, scroll, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 180),
        ])
    }

    private var report: FeedbackReport? {
        let report = FeedbackReport(message: textView.string, environment: environment)
        if report == nil { show(L10n.current.text(.feedbackEmpty), isError: true) }
        return report
    }

    @objc private func mailTapped() {
        guard let report else { return }
        guard let url = report.mailURL, NSWorkspace.shared.open(url) else {
            copy(report)
            show(
                L10n.current.formatted(.feedbackNoMailApp, FeedbackReport.address),
                isError: true)
            return
        }
        show(L10n.current.text(.feedbackMailOpened), isError: false)
    }

    @objc private func issueTapped() {
        guard let report else { return }
        guard let url = report.issueURL, NSWorkspace.shared.open(url) else {
            copy(report)
            show(L10n.current.text(.feedbackNoBrowser), isError: true)
            return
        }
        show(L10n.current.text(.feedbackGitHubOpened), isError: false)
    }

    @objc private func copyTapped() {
        guard let report else { return }
        copy(report)
        show(L10n.current.formatted(.feedbackCopied, FeedbackReport.address), isError: false)
    }

    private func copy(_ report: FeedbackReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.clipboardText, forType: .string)
    }

    private func show(_ message: String, isError: Bool) {
        status.stringValue = message
        status.textColor = isError ? .systemRed : .secondaryLabelColor
    }
}
