import AppKit
import DizunArchive
import DizunCore
import Foundation

/// Pre-extraction preview: the archive's contents, the detected name
/// encoding with instant manual re-decode (ZIP), a format badge for the
/// other supported formats, and a warning for anything this build cannot
/// extract (SPEC §3/§5).
@MainActor
final class ArchivePreviewWindowController: NSObject, NSWindowDelegate {
    /// What the preview table shows. ZIP keeps its first-party reader and
    /// the encoding switch; every other format lists through libarchive.
    private enum Payload {
        case zip(ZipReader)
        case other(format: ArchiveFormat, entries: [LibarchiveArchive.Entry])
    }

    private struct Row {
        let name: String
        let size: UInt64?
        let isDirectory: Bool
    }

    private let archiveURL: URL
    private let payload: Payload
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
    private var rows: [Row] = []

    init?(archiveURL: URL, coordinator: WorkCoordinator, autoQuit: Bool) {
        do {
            switch FormatDetector.detect(url: archiveURL) {
            case .zip, nil:
                guard let reader = try? ZipReader(url: archiveURL) else { return nil }
                payload = .zip(reader)
            case .some(let format):
                let listing = try LibarchiveArchive.list(url: archiveURL)
                payload = .other(format: listing.format, entries: listing.entries)
            }
        } catch {
            return nil
        }
        self.archiveURL = archiveURL
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
        var warnings: [String] = []
        switch payload {
        case .zip(let reader):
            let encoding = chosenEncoding
            let entries = (encoding.map { reader.entriesDecoded(as: $0) } ?? reader.entries)
                .sorted { $0.name < $1.name }
            rows = entries.map { Row(name: $0.name, size: $0.uncompressedSize, isDirectory: $0.isDirectory) }
            let unsupported = entries.filter { $0.method != Zip.methodStore && $0.method != Zip.methodDeflate }
            if !unsupported.isEmpty {
                warnings.append(L10n.unsupportedWarning(unsupported.count))
            }
            let encrypted = entries.filter(\.isEncrypted)
            if !encrypted.isEmpty {
                warnings.append(L10n.encryptedWarning(encrypted.count))
            }
        case .other(let format, let entries):
            rows = entries.sorted { $0.rawName < $1.rawName }
                .map { Row(name: $0.rawName, size: $0.declaredSize, isDirectory: $0.kind == .directory) }
            let encrypted = entries.filter(\.isEncrypted)
            if !encrypted.isEmpty {
                warnings.append(L10n.encryptedWarning(encrypted.count))
            }
            let skipped = entries.filter {
                if case .special = $0.kind { return true }
                return false
            }
            if !skipped.isEmpty {
                warnings.append(L10n.encryptedWarning(skipped.count))
            }
            _ = format
        }
        tableView?.reloadData()

        let total = rows.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
        summaryLabel.stringValue = L10n.summary(
            rows.count, ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))
        warningLabel.stringValue = warnings.joined(separator: "\n")
    }

    // MARK: - Views

    private func makeHeader() -> NSView {
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        var leadingViews: [NSView] = []
        switch payload {
        case .zip(let reader):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let auto = NSMenuItem(title: L10n.encodingAuto(
                reader.detectedEncoding == .cp932 ? L10n.detectedCP932 : L10n.detectedUTF8),
                                  action: #selector(encodingChanged), keyEquivalent: "")
            auto.tag = 0
            let utf8 = NSMenuItem(title: "UTF-8", action: #selector(encodingChanged), keyEquivalent: "")
            utf8.tag = 1
            let cp932 = NSMenuItem(title: L10n.cp932Windows, action: #selector(encodingChanged), keyEquivalent: "")
            cp932.tag = 2
            [auto, utf8, cp932].forEach { $0.target = self }
            popup.menu?.items = [auto, utf8, cp932]
            popup.bezelStyle = .rounded
            encodingPopup = popup
            let label = NSTextField(labelWithString: L10n.fileEncoding + ":")
            label.font = .systemFont(ofSize: 12)
            leadingViews = [label, popup]
        case .other(let format, _):
            // Format badge instead of the encoding switch (non-ZIP names
            // come out of the format's own metadata; no manual re-decode).
            let badge = NSTextField(labelWithString: format.displayName)
            badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            badge.textColor = .secondaryLabelColor
            leadingViews = [badge]
        }
        let spacer = NSView()   // pushes the summary to the trailing edge
        let row = NSStackView(views: leadingViews + [spacer, summaryLabel])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeTable() -> NSScrollView {
        let table = NSTableView()
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = L10n.nameColumn
        nameColumn.width = 400
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = L10n.sizeColumn
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
        warningLabel.textColor = .secondaryLabelColor

        let extract = NSButton(title: L10n.extract, target: self, action: #selector(extractClicked))
        extract.bezelStyle = .push
        extract.keyEquivalent = "\r"
        let cancel = NSButton(title: L10n.cancel, target: self, action: #selector(cancelClicked))
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
            guard let size = entry.size, !entry.isDirectory else { return "" }
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return entry.name
    }
}
