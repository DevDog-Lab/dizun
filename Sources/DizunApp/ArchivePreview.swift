import AppKit
import DizunCore
import Foundation

/// Pre-extraction preview: the archive's contents, the detected name
/// encoding with instant manual re-decode, and a warning for anything this
/// build cannot extract (SPEC §3/§5).
@MainActor
final class ArchivePreviewWindowController: NSObject, NSWindowDelegate {
    private let archiveURL: URL
    private let reader: ZipReader
    private let coordinator: WorkCoordinator
    /// Quit the app when this window's work ends (one-shot launches).
    private let autoQuit: Bool
    /// Called from windowWillClose so the owner can drop its strong reference.
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var encodingPopup: NSPopUpButton?
    private var warningLabel = NSTextField(wrappingLabelWithString: "")
    private var summaryLabel = NSTextField(labelWithString: "")
    private var rows: [ZipEntry] = []

    init?(archiveURL: URL, coordinator: WorkCoordinator, autoQuit: Bool) {
        guard let reader = try? ZipReader(url: archiveURL) else { return nil }
        self.archiveURL = archiveURL
        self.reader = reader
        self.coordinator = coordinator
        self.autoQuit = autoQuit
        super.init()
    }

    func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = archiveURL.lastPathComponent
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]

        let header = makeHeader()
        let tableScroll = makeTable()
        if let table = tableScroll.documentView as? NSTableView {
            tableView = table
        }
        let footer = makeFooter()

        let content = window.contentView!
        content.addSubview(header)
        content.addSubview(tableScroll)
        content.addSubview(footer)
        [header, tableScroll, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tableScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tableScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    // MARK: - Content

    private var chosenEncoding: NameEncoding? {
        switch encodingPopup?.selectedTag() {
        case 1: return .utf8
        case 2: return .cp932
        default: return nil   // 自動
        }
    }

    private func reload() {
        let encoding = chosenEncoding
        let entries = (encoding.map { reader.entriesDecoded(as: $0) } ?? reader.entries)
            .sorted { $0.name < $1.name }
        rows = entries
        tableView?.reloadData()

        let total = entries.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        summaryLabel.stringValue =
            "\(entries.count)項目・\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"

        var warnings: [String] = []
        let unsupported = entries.filter { $0.method != Zip.methodStore && $0.method != Zip.methodDeflate }
        if !unsupported.isEmpty {
            warnings.append("未対応の圧縮方式の項目: \(unsupported.count)件")
        }
        let encrypted = entries.filter(\.isEncrypted)
        if !encrypted.isEmpty {
            warnings.append("パスワード保護された項目: \(encrypted.count)件（解凍時に尋ねます）")
        }
        warningLabel.stringValue = warnings.joined(separator: "\n")
    }

    // MARK: - Views

    private func makeHeader() -> NSView {
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let auto = NSMenuItem(title: "自動判定（\(reader.detectedEncoding == .cp932 ? "CP932" : "UTF-8")）",
                              action: #selector(encodingChanged), keyEquivalent: "")
        auto.tag = 0
        let utf8 = NSMenuItem(title: "UTF-8", action: #selector(encodingChanged), keyEquivalent: "")
        utf8.tag = 1
        let cp932 = NSMenuItem(title: "CP932（Windows）", action: #selector(encodingChanged), keyEquivalent: "")
        cp932.tag = 2
        [auto, utf8, cp932].forEach { $0.target = self }
        popup.menu?.items = [auto, utf8, cp932]
        popup.bezelStyle = .rounded
        encodingPopup = popup

        let label = NSTextField(labelWithString: "ファイル名の文字コード:")
        label.font = .systemFont(ofSize: 12)
        let spacer = NSView()   // pushes the summary to the trailing edge
        let row = NSStackView(views: [label, popup, spacer, summaryLabel])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeTable() -> NSScrollView {
        let table = NSTableView()
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "名前"
        nameColumn.width = 400
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "サイズ"
        sizeColumn.width = 110
        table.addTableColumn(nameColumn)
        table.addTableColumn(sizeColumn)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func makeFooter() -> NSView {
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemRed

        let extract = NSButton(title: "解凍", target: self, action: #selector(extractClicked))
        extract.bezelStyle = .push
        extract.keyEquivalent = "\r"
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancel, extract])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let spacer = NSView()
        let footer = NSStackView(views: [warningLabel, spacer, buttons])
        footer.orientation = .horizontal
        footer.spacing = 12
        return footer
    }

    // MARK: - Actions

    @objc private func encodingChanged() {
        reload()
    }

    @objc private func extractClicked() {
        window?.orderOut(nil)
        let encoding = chosenEncoding
        coordinator.extractAll(archives: [archiveURL], forcedEncoding: encoding) { [weak self] in
            guard let self else { return }
            if self.autoQuit {
                NSApp.terminate(nil)
            } else {
                self.window?.close()
            }
        }
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if autoQuit {
            NSApp.terminate(nil)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

extension ArchivePreviewWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        guard row < rows.count else { return nil }
        let entry = rows[row]
        if tableColumn?.identifier.rawValue == "size" {
            return entry.isDirectory ? ""
                : ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize),
                                            countStyle: .file)
        }
        return entry.name
    }
}
