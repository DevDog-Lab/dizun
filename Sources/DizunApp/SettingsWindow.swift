import AppKit
import DizunCore
import Foundation

/// The standard settings window (⌘,). The image-optimization defaults live
/// here and in the droplet's 画像 tab — both edit the same UserDefaults
/// keys, so they can never disagree.
@MainActor
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private var edgeField: NSTextField?
    private var targetField: NSTextField?
    static let shared = SettingsWindowController()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "設定"
        window.isReleasedWhenClosed = false

        window.collectionBehavior = [.moveToActiveSpace]
        let heading = DizunRows.sectionTitle("画像最適化の既定値")

        let edge = Self.digitsField()
        edge.delegate = self
        edge.stringValue = Settings.optimizeMaxDimension.map(String.init) ?? ""
        edgeField = edge
        let target = Self.digitsField()
        target.delegate = self
        target.stringValue = Settings.optimizeTargetKB.map(String.init) ?? ""
        targetField = target

        let backup = NSButton(checkboxWithTitle: "ゴミ箱へ残す",
                              target: self, action: #selector(backupChanged(_:)))
        backup.state = Settings.optimizeBackupToTrash ? .on : .off
        backup.font = .systemFont(ofSize: 12)

        // Same row rhythm as the droplet's 画像 tab — one setting per row,
        // aligned label column, consistent hints.
        let stack = DizunRows.group([
            heading,
            DizunRows.row(label: "長辺上限", controls: [edge, DizunRows.label("px")],
                          hint: "空欄でリサイズなし"),
            DizunRows.row(label: "目標サイズ", controls: [target, DizunRows.label("KB以下")],
                          hint: "空欄で指定なし"),
            DizunRows.row(label: "元画像", controls: [backup]),
        ], spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.setContentSize(NSSize(width: 380, height: stack.fittingSize.height + 40))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func backupChanged(_ sender: NSButton) {
        Settings.optimizeBackupToTrash = sender.state == .on
    }

    /// Same digits-only behavior as the droplet fields: full-width digits
    /// (IME) convert to half-width, anything else is dropped, live-saved.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field == edgeField || field == targetField else { return }
        let digits = Self.sanitize(field.stringValue)
        if digits != field.stringValue {
            field.stringValue = digits
        }
        if field == edgeField {
            Settings.optimizeMaxDimension = Int(digits)
        } else {
            Settings.optimizeTargetKB = Int(digits)
        }
    }

    nonisolated static func sanitize(_ raw: String) -> String {
        let fullWidth: [Character: Character] = [
            "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
            "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
        ]
        return String(String(raw.map { fullWidth[$0] ?? $0 }).prefix(5)
            .filter { $0.isASCII && $0.isNumber })
    }

    nonisolated static func digitsField() -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 52, height: 24))
        field.placeholderString = "なし"
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.usesSingleLineMode = true
        return field
    }
}
