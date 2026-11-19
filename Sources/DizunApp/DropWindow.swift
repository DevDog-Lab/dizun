import AppKit
import DizunCore
import Foundation

/// The plain-launch window: explains what DIZUN does and accepts drops.
/// ZIPs are extracted, everything else is compressed — same heuristic the
/// open/service paths use.
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "DIZUN"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        let title = NSTextField(labelWithString: "DIZUN")
        title.font = .boldSystemFont(ofSize: 26)
        let subtitle = NSTextField(wrappingLabelWithString:
            "ZIPはここにドロップして解凍、ほかのファイル/フォルダは圧縮します。Finderの右クリックメニュー（サービス）からも使えます。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let drop = DropView()
        drop.onDrop = { [weak self] urls in
            self?.coordinator.performAutomatic(urls: urls) {}
        }

        // Compression encoding, persisted (CP932 for legacy Japanese Windows
        // tools; unmappable names stop the write with an error, never mangle).
        let encodingLabel = NSTextField(labelWithString: "圧縮時のファイル名:")
        encodingLabel.font = .systemFont(ofSize: 12)
        let encoding = NSSegmentedControl(
            labels: ["UTF-8（標準）", "CP932（Windows互換）"],
            trackingMode: .selectOne, target: self, action: #selector(encodingChanged(_:)))
        encoding.segmentStyle = .texturedRounded
        encoding.selectedSegment = Settings.compressEncoding == .cp932 ? 1 : 0

        // Encryption scheme, persisted; the password itself is asked per job.
        let cryptoLabel = NSTextField(labelWithString: "暗号化:")
        cryptoLabel.font = .systemFont(ofSize: 12)
        let crypto = NSSegmentedControl(
            labels: ["なし", "AES-256", "ZipCrypto（弱い）"],
            trackingMode: .selectOne, target: self, action: #selector(encryptionChanged(_:)))
        crypto.segmentStyle = .texturedRounded
        switch Settings.compressEncryptionKind {
        case .none: crypto.selectedSegment = 0
        case .aes256: crypto.selectedSegment = 1
        case .zipCrypto: crypto.selectedSegment = 2
        }
        let encodingRow = NSStackView(views: [encodingLabel, encoding,
                                              NSStackView.spacerView, cryptoLabel, crypto])
        encodingRow.orientation = .horizontal
        encodingRow.spacing = 8

        // Image optimization: custom long-edge cap (px), JPEG target size
        // (KB), and Trash backup for originals. Fields are digits-only.
        let resizeLabel = NSTextField(labelWithString: "画像最適化:")
        resizeLabel.font = .systemFont(ofSize: 12)
        // Built by concatenation: the release optimizer has been observed
        // dropping these exact two-literal labels from the binary.
        let edgeLabel = NSTextField(labelWithString: "長" + "辺")
        edgeLabel.font = .systemFont(ofSize: 12)
        let edge = numberField(placeholder: "なし")
        edge.stringValue = Settings.optimizeMaxDimension.map(String.init) ?? ""
        edgeField = edge
        let edgeUnit = NSTextField(labelWithString: "px")
        edgeUnit.font = .systemFont(ofSize: 12)
        let targetLabel = NSTextField(labelWithString: "目標")
        targetLabel.font = .systemFont(ofSize: 12)
        let target = numberField(placeholder: "なし")
        target.stringValue = Settings.optimizeTargetKB.map(String.init) ?? ""
        targetField = target
        let targetUnit = NSTextField(labelWithString: String("KB以" + "下"))
        targetUnit.font = .systemFont(ofSize: 12)
        let optimizeRow = NSStackView(views: [resizeLabel, edgeLabel, edge, edgeUnit,
                                              targetLabel, target, targetUnit])
        optimizeRow.orientation = .horizontal
        optimizeRow.spacing = 6

        let backupToggle = NSButton(checkboxWithTitle: "元画像をゴミ箱へ（最適化の前に元ファイルを退避）",
                                    target: self, action: #selector(backupChanged(_:)))
        backupToggle.state = Settings.optimizeBackupToTrash ? .on : .off

        let stack = NSStackView(views: [title, subtitle, drop, encodingRow, optimizeRow, backupToggle])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            drop.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            drop.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        // Size the window to what the rows actually need (a fixed height
        // used to clip the bottom row out of view).
        let fitting = stack.fittingSize
        window.setContentSize(NSSize(width: max(520, fitting.width + 48),
                                     height: fitting.height + 40))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func encodingChanged(_ sender: NSSegmentedControl) {
        Settings.compressEncoding = sender.selectedSegment == 1 ? .cp932 : .utf8
    }

    @objc private func edgeChanged(_ sender: NSTextField) {
        Settings.optimizeMaxDimension = Int(sender.stringValue)
    }

    @objc private func targetChanged(_ sender: NSTextField) {
        Settings.optimizeTargetKB = Int(sender.stringValue)
    }

    /// Digits-only fields: full-width digits (IME) are converted to
    /// half-width and everything else is dropped as it is typed, so the
    /// active field effectively behaves as half-width numeric input.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field == edgeField || field == targetField else { return }
        let fullWidth: [Character: Character] = [
            "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
            "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
        ]
        let converted = String(field.stringValue.map { fullWidth[$0] ?? $0 })
        let digits = String(converted.prefix(5).filter { $0.isASCII && $0.isNumber })
        if digits != field.stringValue {
            field.stringValue = digits
        }
        if field == edgeField {
            Settings.optimizeMaxDimension = Int(digits)
        } else {
            Settings.optimizeTargetKB = Int(digits)
        }
    }

    private func numberField(placeholder: String) -> NSTextField {
        // Just wide enough for five digits — keeps the settings row inside
        // the window at every localization width.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 52, height: 24))
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.usesSingleLineMode = true
        return field
    }

    @objc private func backupChanged(_ sender: NSButton) {
        Settings.optimizeBackupToTrash = sender.state == .on
    }

    @objc private func encryptionChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: Settings.compressEncryptionKind = .aes256
        case 2: Settings.compressEncryptionKind = .zipCrypto
        default: Settings.compressEncryptionKind = .none
        }
    }
}

extension NSStackView {
    /// A flexible spacer for stack rows (AppKit has no built-in one).
    static var spacerView: NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
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
