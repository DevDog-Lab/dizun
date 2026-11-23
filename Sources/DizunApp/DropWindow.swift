import AppKit
import DizunArchive
import DizunCore
import Foundation

/// The plain-launch window: explains what DIZUN does and accepts drops.
/// ZIPs are extracted, images are optimized, everything else is compressed.
/// Settings live in two tabs so ZIP and image concerns stay separate.
@MainActor
final class DropletWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let coordinator: WorkCoordinator
    private var window: NSWindow?
    private var edgeField: NSTextField?
    private var targetField: NSTextField?
    private var nameField: NSTextField?
    private var settingsPages: [NSView] = []
    /// Compression format chosen in this window's lifetime. Session-only
    /// by design: every launch starts from ZIP so nothing gets sent in a
    /// format the recipient cannot open by accident.
    private var sessionFormat: ArchiveFormat = .zip
    private var encodingControl: NSSegmentedControl?
    private var cryptoControl: NSSegmentedControl?
    private var formatHintLabel: NSTextField?
    private var contentStack: NSStackView?
    private var resultLabel = NSTextField(wrappingLabelWithString: "")
    private var dropCaption = NSTextField(labelWithString: L10n.dropHere)
    private var dropHint = NSTextField(labelWithString: L10n.dropHint)

    init(coordinator: WorkCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func show() {
        window?.close()
        sessionFormat = .zip
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        // Fully standard chrome: standard titlebar, standard 14px traffic
        // lights, exactly like every other app. (The earlier edge-to-edge
        // blue needed a transparent titlebar, which switches macOS to its
        // compact 12px button set — the "smaller than other apps" look.)
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = NSColor(srgbRed: 0x4F / 255, green: 0x91 / 255,
                                         blue: 0xDD / 255, alpha: 1)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]

        // Brand wordmark (user-designed unzip/dizun rotation logo).
        let title = NSImageView(image: NSImage(contentsOfFile:
            Bundle.main.path(forResource: "logo", ofType: "png")
                ?? Bundle.main.bundlePath + "/Contents/Resources/logo.png") ?? NSImage())
        let aspect = title.image?.size.height ?? 1 > 0
            ? (title.image!.size.width / max(title.image!.size.height, 1)) : 4
        // Sized to the window chrome: ~3x the close button's 12pt diameter.
        title.heightAnchor.constraint(equalToConstant: 36).isActive = true
        title.widthAnchor.constraint(equalToConstant: 36 * aspect).isActive = true
        title.imageScaling = .scaleProportionallyUpOrDown
        _ = aspect

        // ZIP / image / anything-else routing in one calm sentence.
        let drop = DropView()
        drop.onDrop = { [weak self] urls in
            self?.clearResult()
            self?.coordinator.performAutomatic(urls: urls, format: self?.sessionFormat ?? .zip) {}
        }
        dropCaption.font = .systemFont(ofSize: 13)
        dropCaption.textColor = .white
        dropHint.font = .systemFont(ofSize: 11)
        dropHint.textColor = NSColor.white.withAlphaComponent(0.75)
        resultLabel = NSTextField(wrappingLabelWithString: "")
        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.textColor = .white
        resultLabel.alignment = .center
        resultLabel.isHidden = true
        let dropStack = NSStackView(views: [dropCaption, dropHint, resultLabel])
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
            [L10n.tabArchive, L10n.tabImages], target: self,
            action: #selector(settingsTabChanged(_:)), selected: 0)
        if #available(macOS 27.0, *) {
            selector.role = .valueSelection
        }
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
        panel.borderColor = NSColor.white.withAlphaComponent(0.6)
        // A matte blue backing gives the system selection lens a darker ground.
        panel.fillColor = NSColor(srgbRed: 0x3B / 255, green: 0x6D / 255,
                                  blue: 0xA6 / 255, alpha: 1)
        panel.cornerRadius = 10
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
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            drop.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            panel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.window = window
        // Job summaries land in the drop area until the next drop
        // (per-file detail for images).
        coordinator.reportResult = { [weak self] summary in
            DispatchQueue.main.async {
                self?.showResult(summary)
            }
        }
        fitWindowToContent()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Job summaries land in the drop area until the next drop.
    private func showResult(_ summary: String) {
        resultLabel.stringValue = summary
        resultLabel.isHidden = false
        dropHint.isHidden = true
        dropCaption.stringValue = L10n.done
    }

    private func clearResult() {
        resultLabel.stringValue = ""
        resultLabel.isHidden = true
        dropHint.isHidden = false
        dropCaption.stringValue = L10n.dropHere
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
        // Format picker: one flat menu, ZIP as the default. The
        // encoding/encryption rows only apply to ZIP and are disabled for
        // the other formats (with an explicit note, never silently).
        let formats: [ArchiveFormat] = [.zip, .tarGz, .tar, .tarBz2, .tarXz, .sevenZ]
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        // Target/action goes on the popup itself (same pattern as the
        // segmented rows): per-item targets proved unreliable here — the
        // menu showed the change while the session variable never heard
        // about it, so drops kept producing ZIPs.
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        for (index, format) in formats.enumerated() {
            let item = NSMenuItem(title: L10n.formatMenuLabel(format),
                                  action: nil, keyEquivalent: "")
            item.tag = index
            formatPopup.menu?.addItem(item)
        }
        formatPopup.selectItem(at: 0)
        let formatHintField = NSTextField(labelWithString: L10n.formatHint(.zip))
        formatHintField.font = .systemFont(ofSize: 11)
        formatHintField.textColor = NSColor.white.withAlphaComponent(0.75)
        formatHintLabel = formatHintField

        let encoding = DizunRows.segmented(
            [L10n.utf8Standard, L10n.cp932Windows],
            target: self, action: #selector(encodingChanged(_:)),
            selected: Settings.compressEncoding == .cp932 ? 1 : 0)
        let cryptoSelection: Int
        switch Settings.compressEncryptionKind {
        case .none: cryptoSelection = 0
        case .aes256: cryptoSelection = 1
        case .zipCrypto: cryptoSelection = 2
        }
        let crypto = DizunRows.segmented(
            [L10n.none, "AES-256", "ZipCrypto"],
            target: self, action: #selector(encryptionChanged(_:)),
            selected: cryptoSelection)
        if #available(macOS 27.0, *) {
            encoding.role = .valueSelection
            crypto.role = .valueSelection
        }
        encodingControl = encoding
        cryptoControl = crypto
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        // Swap the centered cell in FIRST, then configure everything.
        // NSTextField forwards isEditable/isBordered/font/placeholder to
        // its cell, so a later swap drops every earlier setting (the bare
        // textCell init defaults to editable=false — that is what broke
        // editing and hid the placeholder in the previous build).
        name.cell = DizunCenteredTextFieldCell(textCell: "")
        name.isEditable = true
        name.isSelectable = true
        name.font = .systemFont(ofSize: 12)
        // The complete Japanese hint is ~170pt at 10pt, fitting the 174pt
        // text area of the required 180pt field. Entered text stays 12pt.
        name.placeholderAttributedString = NSAttributedString(
            string: L10n.archiveNameHint,
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.systemGray])
        name.usesSingleLineMode = true
        name.cell?.isScrollable = true
        name.lineBreakMode = .byClipping
        // Classic bordered field (not the Liquid Glass bezel, which ignores
        // background painting): white fill, black text.
        name.isBezeled = false
        name.isBordered = true
        name.drawsBackground = true
        name.backgroundColor = .white
        name.textColor = .black
        name.heightAnchor.constraint(equalToConstant: 26).isActive = true
        // An editable field's intrinsic size ignores its frame under Auto
        // Layout — pin the width explicitly (same as the digits fields).
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        name.setContentHuggingPriority(.required, for: .horizontal)

        name.delegate = self
        name.stringValue = Settings.archiveBaseName ?? ""
        nameField = name
        let formatLine = NSStackView(views: [formatPopup])
        formatLine.orientation = .horizontal
        formatLine.spacing = 8
        formatLine.alignment = .centerY
        return DizunRows.group([
            DizunRows.row(label: L10n.archiveFormat, controls: [formatPopup], tinted: true),
            DizunRows.row(label: L10n.archiveFileName, controls: [name], tinted: true),
            DizunRows.row(label: L10n.fileEncoding, controls: [encoding], tinted: true),
            DizunRows.row(label: L10n.encryption, controls: [crypto],
                          hint: L10n.nestedHint, tinted: true),
        ])
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        let order: [ArchiveFormat] = [.zip, .tarGz, .tar, .tarBz2, .tarXz, .sevenZ]
        guard sender.selectedTag() < order.count else { return }
        let format = order[sender.selectedTag()]
        sessionFormat = format
        // Encoding and encryption are ZIP-only; show that honestly instead
        // of silently dropping the settings.
        encodingControl?.isEnabled = format == .zip
        cryptoControl?.isEnabled = format == .zip
        var hint = L10n.formatHint(format)
        if format != .zip {
            let note = L10n.noEncryptionForFormat
            hint = hint.isEmpty ? note : hint + " · " + note
        }
        formatHintLabel?.stringValue = hint
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

        let backup = NSButton(checkboxWithTitle: L10n.keepInTrash,
                              target: self, action: #selector(backupChanged(_:)))
        backup.state = Settings.optimizeBackupToTrash ? .on : .off
        backup.font = .systemFont(ofSize: 12)
        backup.attributedTitle = NSAttributedString(
            string: L10n.keepInTrash,
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12)])

        return DizunRows.group([
            DizunRows.row(label: L10n.longEdgeLimit, controls: [edge, DizunRows.tintedLabel("px")],
                          hint: L10n.blankNoResize, tinted: true),
            DizunRows.row(label: L10n.targetSize, controls: [target, DizunRows.tintedLabel(L10n.kbOrLess)],
                          hint: L10n.blankNone, tinted: true),
            DizunRows.row(label: L10n.originals, controls: [backup], tinted: true),
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
        guard let field = notification.object as? NSTextField else { return }
        if field == nameField {
            Settings.archiveBaseName = field.stringValue
            return
        }
        guard field == edgeField || field == targetField else { return }
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
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
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
