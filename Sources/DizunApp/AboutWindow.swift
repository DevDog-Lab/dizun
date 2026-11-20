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
        window.title = L10n.aboutTitle
        window.isReleasedWhenClosed = false

        window.collectionBehavior = [.moveToActiveSpace]
        let title = NSImageView(image: NSImage(contentsOfFile:
            Bundle.main.path(forResource: "logo", ofType: "png")
                ?? Bundle.main.bundlePath + "/Contents/Resources/logo.png") ?? NSImage())
        title.imageScaling = .scaleProportionallyUpOrDown
        let aspect = (title.image?.size.width ?? 1) / max(title.image?.size.height ?? 1, 1)
        title.heightAnchor.constraint(equalToConstant: 44).isActive = true
        title.widthAnchor.constraint(equalToConstant: 44 * aspect).isActive = true
        let chip = NSBox()
        chip.boxType = .custom
        chip.titlePosition = .noTitle
        chip.borderWidth = 0
        chip.fillColor = NSColor(srgbRed: 0x4F / 255, green: 0x91 / 255, blue: 0xDD / 255, alpha: 1)
        chip.cornerRadius = 8
        chip.contentViewMargins = .zero
        let chipContent = chip.contentView!
        chipContent.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: chipContent.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: chipContent.centerYAnchor),
            chip.widthAnchor.constraint(equalTo: title.widthAnchor, constant: 24),
            chip.heightAnchor.constraint(equalTo: title.heightAnchor, constant: 16),
        ])
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let versionLabel = NSTextField(labelWithString: L10n.versionLine(version))
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        let blurb = NSTextField(wrappingLabelWithString: L10n.aboutBlurb)
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor

        let link = NSButton(title: L10n.openReadme, target: self, action: #selector(openReadme))
        link.bezelStyle = .rounded

        let stack = NSStackView(views: [chip, versionLabel, blurb, link])
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
