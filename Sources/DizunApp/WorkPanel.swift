import AppKit
import Foundation

/// Small accessory progress panel: what is happening, what was skipped, and
/// a cancel button. Main-thread only; callers from the work queue hop with
/// DispatchQueue.main.
@MainActor
final class WorkPanel {
    static let shared = WorkPanel()

    private var window: NSWindow?
    private var titleLabel = NSTextField(labelWithString: "")
    private var itemLabel = NSTextField(labelWithString: "")
    private var noticeLabel = NSTextField(wrappingLabelWithString: "")
    private var indicator = NSProgressIndicator()
    private var cancelButton: NSButton?

    private init() {}

    func begin(title: String, label: String, onCancel: @escaping () -> Void) {
        if window == nil { buildWindow() }
        guard let window else { return }
        titleLabel.stringValue = title
        itemLabel.stringValue = label
        noticeLabel.stringValue = ""
        indicator.startAnimation(nil)
        cancelButton?.title = L10n.cancel
        cancelButton?.isEnabled = true
        cancelHandler = onCancel
        if !window.isVisible {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLabel(_ text: String) {
        itemLabel.stringValue = text
    }

    func setNotice(_ text: String) {
        noticeLabel.stringValue = text
    }

    func end() {
        indicator.stopAnimation(nil)
        window?.orderOut(nil)
        cancelHandler = nil
    }

    /// Brief message without a running job (e.g. double drop while busy).
    func flashBusy() {
        let alert = NSAlert()
        alert.messageText = L10n.busyMessage
        alert.runModal()
    }

    func flash(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    /// Synchronous error report; returns after the user acknowledges.
    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.problemTitle
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var cancelHandler: (() -> Void)?

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 168),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "DIZUN"
        window.isReleasedWhenClosed = false

        window.collectionBehavior = [.moveToActiveSpace]
        window.level = .floating

        titleLabel.font = .boldSystemFont(ofSize: 15)
        itemLabel.font = .systemFont(ofSize: 12)
        itemLabel.textColor = .secondaryLabelColor
        itemLabel.lineBreakMode = .byTruncatingMiddle
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 2

        indicator.style = .bar
        indicator.isIndeterminate = true   // barber pole; byte counts come later
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false

        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancelButton = cancel

        let stack = NSStackView(views: [titleLabel, itemLabel, indicator, noticeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        let content = window.contentView!
        content.addSubview(stack)
        content.addSubview(cancel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cancel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: cancel.topAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        self.window = window
    }

    @objc private func cancelClicked() {
        cancelButton?.isEnabled = false
        itemLabel.stringValue = L10n.cancelling
        cancelHandler?()
    }
}
