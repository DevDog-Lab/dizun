import AppKit
import DizunCore
import Foundation

/// About panel: brand, version, and the GitHub README link (user-initiated
/// browser open; no network code runs inside DIZUN itself).
@MainActor
final class AboutWindowController {
    private var window: NSWindow?
    static let shared = AboutWindowController()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "DIZUNについて"
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "DIZUN")
        title.font = .boldSystemFont(ofSize: 28)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let versionLabel = NSTextField(labelWithString: "バージョン \(version)（開発中・未リリース）")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        let blurb = NSTextField(wrappingLabelWithString:
            "圧縮と解凍をひとつにした、macOS向けアーカイブアプリ。日本語ファイル名とWindows/macOS間の互換性を重視します。")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        let link = NSButton(title: "GitHub README を開く", target: self, action: #selector(openReadme))
        link.bezelStyle = .rounded

        let stack = NSStackView(views: [title, versionLabel, blurb, link])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func openReadme() {
        if let url = URL(string: "https://github.com/DevDog-Lab/dizun#readme") {
            NSWorkspace.shared.open(url)
        }
    }
}
