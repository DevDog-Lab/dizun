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
    private var settingsPages: [NSView] = []
    private var contentStack: NSStackView?

    init(coordinator: WorkCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "DIZUN"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]

        let title = NSTextField(labelWithString: "DIZUN")
        title.font = .boldSystemFont(ofSize: 22)
        title.alignment = .left

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

        // A full-width standard selector and its content share one panel.
        let selector = DizunRows.segmented(
            ["圧縮・解凍", "画像最適化"], target: self,
            action: #selector(settingsTabChanged(_:)), selected: 0)
        selector.segmentDistribution = .fill
        selector.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settingsPages = [zipTab(), imageTab()]
        settingsPages[1].isHidden = true
        let pages = DizunRows.group(settingsPages)
        pages.detachesHiddenViews = true
        let panelStack = DizunRows.group([selector, pages], spacing: 16)
        panelStack.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSBox()
        panel.boxType = .custom
        panel.titlePosition = .noTitle
        panel.borderWidth = 1
        panel.borderColor = .separatorColor
        panel.fillColor = .controlBackgroundColor
        panel.cornerRadius = 8
        panel.contentViewMargins = .zero
        let panelContent = panel.contentView!
        panelContent.addSubview(panelStack)
        NSLayoutConstraint.activate([
            panelStack.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 16),
            panelStack.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -16),
            panelStack.topAnchor.constraint(equalTo: panelContent.topAnchor, constant: 16),
            panelStack.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor, constant: -16),
            selector.widthAnchor.constraint(equalTo: panelStack.widthAnchor),
            pages.widthAnchor.constraint(equalTo: panelStack.widthAnchor),
        ])

        let stack = NSStackView(views: [title, drop, panel])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            drop.heightAnchor.constraint(equalToConstant: 120),
            panel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.window = window
        fitWindowToContent()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
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

    @objc private func settingsTabChanged(_ sender: NSSegmentedControl) {
        for (index, page) in settingsPages.enumerated() {
            page.isHidden = index != sender.selectedSegment
        }
        fitWindowToContent()
    }

    /// Keep all four outer insets equal without stretching a sparse settings
    /// page. Preserve the top edge when changing tabs.
    private func fitWindowToContent() {
        guard let window, let contentStack else { return }
        let top = window.frame.maxY
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 560, height: contentStack.fittingSize.height + 36))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
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
            DizunRows.row(label: "圧縮時のファイル名", controls: [
                DizunRows.hint("例）報告書.zip ／ 複数なら Archive.zip"),
            ]),
            DizunRows.row(label: "ファイル名の文字コード", controls: [encoding]),
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

        let backup = NSButton(checkboxWithTitle: "ゴミ箱へ残す",
                              target: self, action: #selector(backupChanged(_:)))
        backup.state = Settings.optimizeBackupToTrash ? .on : .off
        backup.font = .systemFont(ofSize: 12)

        return DizunRows.group([
            DizunRows.row(label: "長辺上限", controls: [edge, DizunRows.label("px")],
                          hint: "空欄でリサイズなし"),
            DizunRows.row(label: "目標サイズ", controls: [target, DizunRows.label("KB以下")],
                          hint: "空欄で指定なし"),
            DizunRows.row(label: "元画像", controls: [backup]),
        ], spacing: 12)
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
