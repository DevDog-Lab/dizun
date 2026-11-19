import AppKit
import DizunCore
import Foundation

/// The plain-launch window: explains what DIZUN does and accepts drops.
/// ZIPs are extracted, images are optimized, everything else is compressed.
/// Settings live in two tabs so ZIP and image concerns stay separate.
final class DropletWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let coordinator: WorkCoordinator
    private var window: NSWindow?
    private var edgeField: NSTextField?
    private var targetField: NSTextField?

    init(coordinator: WorkCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "DIZUN"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]

        let title = NSTextField(labelWithString: "DIZUN")
        title.font = .boldSystemFont(ofSize: 22)

        // ZIP / image / anything-else routing in one calm sentence.
        let drop = DropView()
        drop.onDrop = { [weak self] urls in
            self?.coordinator.performAutomatic(urls: urls) {}
        }
        let dropCaption = NSTextField(labelWithString: "ここにドロップ")
        dropCaption.font = .systemFont(ofSize: 13)
        let dropHint = NSTextField(labelWithString: "ZIPは解凍・画像は最適化・ほかは圧縮")
        dropHint.font = .systemFont(ofSize: 11)
        dropHint.textColor = .tertiaryLabelColor
        let dropStack = NSStackView(views: [dropCaption, dropHint])
        dropStack.orientation = .vertical
        dropStack.alignment = .centerX
        dropStack.spacing = 4
        drop.addSubview(dropStack)
        dropStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dropStack.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            dropStack.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
        ])

        // Tabs: ZIP settings and image settings never share a row.
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tabItem(label: "圧縮・解凍", view: zipTab()))
        tabs.addTabViewItem(tabItem(label: "画像最適化", view: imageTab()))

        let stack = NSStackView(views: [title, drop, tabs])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            drop.heightAnchor.constraint(equalToConstant: 140),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// Re-assert visibility (used by the delayed launch kick): brings the
    /// window front on the active space even when the first attempt lost a
    /// focus race with another app.
    func showWindowAgain() {
        guard let window else { return }
        window.collectionBehavior = [.moveToActiveSpace]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func tabItem(label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    /// One setting per row, aligned label column.
    private func zipTab() -> NSView {
        let encoding = DizunRows.segmented(
            ["UTF-8（標準）", "CP932（Windows互換）"],
            target: self, action: #selector(encodingChanged(_:)),
            selected: Settings.compressEncoding == .cp932 ? 1 : 0)
        let cryptoSelection: Int
        switch Settings.compressEncryptionKind {
        case .none: cryptoSelection = 0
        case .aes256: cryptoSelection = 1
        case .zipCrypto: cryptoSelection = 2
        }
        let crypto = DizunRows.segmented(
            ["なし", "AES-256", "ZipCrypto"],
            target: self, action: #selector(encryptionChanged(_:)),
            selected: cryptoSelection)
        return DizunRows.group([
            DizunRows.row(label: "圧縮時のファイル名", controls: [encoding]),
            DizunRows.row(label: "暗号化", controls: [crypto],
                          hint: "二重ZIPで構成も隠す"),
        ])
    }

    private func imageTab() -> NSView {
        let edge = SettingsWindowController.digitsField()
        edge.delegate = self
        edge.stringValue = Settings.optimizeMaxDimension.map(String.init) ?? ""
        edgeField = edge
        let target = SettingsWindowController.digitsField()
        target.delegate = self
        target.stringValue = Settings.optimizeTargetKB.map(String.init) ?? ""
        targetField = target

        let backup = NSButton(checkboxWithTitle: "元画像をゴミ箱へ残す",
                              target: self, action: #selector(backupChanged(_:)))
        backup.state = Settings.optimizeBackupToTrash ? .on : .off
        backup.font = .systemFont(ofSize: 12)

        return DizunRows.group([
            DizunRows.row(label: "長辺上限", controls: [edge, DizunRows.label("px")],
                          hint: "空欄でリサイズなし"),
            DizunRows.row(label: "目標サイズ", controls: [target, DizunRows.label("KB以下")],
                          hint: "空欄で指定なし"),
            backup,
        ], spacing: 16)
    }

    // MARK: - Actions

    @objc private func encodingChanged(_ sender: NSSegmentedControl) {
        Settings.compressEncoding = sender.selectedSegment == 1 ? .cp932 : .utf8
    }

    @objc private func encryptionChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: Settings.compressEncryptionKind = .aes256
        case 2: Settings.compressEncryptionKind = .zipCrypto
        default: Settings.compressEncryptionKind = .none
        }
    }

    @objc private func backupChanged(_ sender: NSButton) {
        Settings.optimizeBackupToTrash = sender.state == .on
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field == edgeField || field == targetField else { return }
        let digits = SettingsWindowController.sanitize(field.stringValue)
        if digits != field.stringValue {
            field.stringValue = digits
        }
        if field == edgeField {
            Settings.optimizeMaxDimension = Int(digits)
        } else {
            Settings.optimizeTargetKB = Int(digits)
        }
    }
}

/// Bare drag-and-drop target with a simple rounded border.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    required init?(coder: NSCoder) { fatalError("not used") }

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func files(_ sender: NSDraggingInfo) -> [URL] {
        guard let items = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self],
                         options: [.urlReadingFileURLsOnly: true]) as? [NSURL] else {
            return []
        }
        return items.compactMap { $0 as URL }
    }
}
