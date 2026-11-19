import AppKit
import Foundation

/// Modal password prompts (NSAlert + accessory secure fields). Returns nil
/// when the user cancels. Passwords live only in the returned String and are
/// never logged or persisted.
@MainActor
enum PasswordPrompt {
    /// Ask for an existing archive's password.
    static func ask(title: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.passwordRequired
        alert.informativeText = title
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.cancel)
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Ask for a new password twice; nil on cancel, retries on mismatch.
    static func requestNew() -> String? {
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.newPasswordTitle
            alert.informativeText = L10n.newPasswordInfo
            let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
            stack.orientation = .vertical
            stack.spacing = 8
            let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            first.placeholderString = L10n.passwordField
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            second.placeholderString = L10n.passwordConfirm
            stack.addArrangedSubview(first)
            stack.addArrangedSubview(second)
            alert.accessoryView = stack
            alert.addButton(withTitle: L10n.createEncrypted)
            alert.addButton(withTitle: L10n.cancel)
            alert.window.initialFirstResponder = first
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            guard !first.stringValue.isEmpty else { continue }
            guard first.stringValue == second.stringValue else {
                let mismatch = NSAlert()
                mismatch.messageText = L10n.passwordMismatch
                mismatch.runModal()
                continue
            }
            return first.stringValue
        }
    }
}
