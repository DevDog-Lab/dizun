import AppKit
import DizunArchive
import DizunCore
import DizunImage
import Foundation

/// Runs compression/extraction jobs on a background queue and reports to the
/// progress panel. Alerts are synchronous so one-shot termination never
/// overtakes them.
private var lang: AppLanguage { L10n.lang }

final class WorkCoordinator {
    private let queue = DispatchQueue(label: "com.devdoglab.dizun.work", qos: .userInitiated)
    private var busy = false
    /// Set false by smoke runs (DIZUN_NO_REVEAL) to keep Finder out of CI.
    private let revealInFinder = ProcessInfo.processInfo.environment["DIZUN_NO_REVEAL"] == nil

    // MARK: - Job dispatch

    /// Set by the app delegate: single-archive opens go to the preview
    /// window instead of extracting immediately (unless the user chose
    /// instant extraction in Settings).
    var openPreview: ((URL) -> Void)?
    /// Password prompts, injected so the coordinator stays UI-free-ish.
    /// `confirm == true` asks twice (new password). Always main-thread.
    var requestPassword: ((_ title: String, _ confirm: Bool) -> String?)?
    /// Job summaries for the droplet's result area (called from the work
    /// queue; the receiver hops to main itself).
    var reportResult: ((String) -> Void)?

    /// Drop / open heuristic: archives (any supported format, detected by
    /// content) → extract, images only → optimize, anything else → compress.
    /// A lone archive is routed to the preview first when one is configured.
    func performAutomatic(urls: [URL], format: ArchiveFormat = .zip,
                          completion: @escaping () -> Void) {
        let images = urls.filter(ImageOptimizer.isSupported)
        if images.count == urls.count, !images.isEmpty {
            optimizeImages(images, completion: completion)
            return
        }
        let archives = urls.filter { FormatDetector.detect(url: $0) != nil }
        if archives.count == urls.count, !archives.isEmpty {
            if archives.count == 1, !Settings.instantExtract, let openPreview {
                openPreview(archives[0])
                return
            }
            extractAll(archives: archives, completion: completion)
        } else {
            compress(files: urls, format: format, completion: completion)
        }
    }

    func extractAll(archives: [URL], forcedEncoding: NameEncoding? = nil,
                    password: String? = nil,
                    completion: (() -> Void)? = nil) {
        // Non-ZIP formats have no password pre-check: the libarchive path
        // reports encrypted members as a clear error instead.
        let zips = archives.filter { FormatDetector.detect(url: $0) == .zip }
        let others = archives.filter { FormatDetector.detect(url: $0) != .zip }
        if !others.isEmpty {
            extractNonZip(others, completion: completion)
            if !zips.isEmpty {
                // Rare mix; run the ZIPs afterwards through the same panel.
                extractAll(archives: zips, forcedEncoding: forcedEncoding,
                           password: password, completion: nil)
            }
            return
        }
        // Ask for the password up front — the engine refuses to touch the
        // disk without one, and prompting before the panel starts keeps the
        // retry clean.
        var password = password
        if password == nil {
            for archive in archives {
                guard let reader = try? ZipReader(url: archive) else { continue }
                if reader.entries.contains(where: { $0.isEncrypted && !$0.isDirectory }) {
                    guard let supplied = requestPassword?(
                        L10n.protectedArchive(archive.lastPathComponent), false) else {
                        completion?()
                        return
                    }
                    password = supplied
                    break
                }
            }
        }
        run(panelTitle: L10n.extract,
            panelLabel: archives.first?.lastPathComponent ?? "") { job in
            var revealed = false
            var failures: [String] = []
            var extractedNames: [String] = []
            for (index, archive) in archives.enumerated() {
                if job.isCancelled { throw DizunError.cancelled }
                let prefix = archives.count > 1 ? "（\(index + 1)/\(archives.count)）" : ""
                job.update("\(archive.lastPathComponent)\(prefix)")
                do {
                    var options = Unpacker.Options()
                    options.forcedEncoding = forcedEncoding
                    options.password = password
                    let result = try Unpacker.unpack(zipURL: archive,
                                                     options: options,
                                                     progress: { job.update($0) },
                                                     shouldCancel: { job.isCancelled })
                    job.notice(Self.notice(for: result))
                    if !revealed {
                        job.reveal(result.extractedTopItems)
                        revealed = true
                    }
                    extractedNames.append(contentsOf: result.extractedTopItems.map { $0.lastPathComponent })
                } catch {
                    if archives.count == 1 { throw error }
                    failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { job.alert(failures.joined(separator: "\n")) }
            let names = extractedNames.prefix(3).joined(separator: lang.isEN ? ", " : "、")
            if !names.isEmpty {
                self.reportResult?(L10n.extractionDone(names, more: extractedNames.count - 3))
            }
        } completion: {
            completion?()
        }
    }

    /// Where a compression job's encryption comes from. Services are
    /// explicit (`plain`/`encrypted`); drops use the persisted setting.
    enum CompressMode {
        case fromSettings
        case plain
        case encrypted
    }

    /// Image-only drops: optimize in place (see ImageOptimizer). The
    /// original goes to the Trash first when the setting says so.
    func optimizeImages(_ urls: [URL], completion: (() -> Void)? = nil) {
        let targets = urls.filter(ImageOptimizer.isSupported)
        guard !targets.isEmpty else {
            completion?()
            return
        }
        run(panelTitle: L10n.optimizeTitle,
            panelLabel: targets.first?.lastPathComponent ?? "") { job in
            var totalBefore = 0
            var totalAfter = 0
            var shrunk = 0
            var lines: [String] = []
            for (index, url) in targets.enumerated() {
                if job.isCancelled { throw DizunError.cancelled }
                job.update("（\(index + 1)/\(targets.count)）\(url.lastPathComponent)")
                var options = ImageOptimizer.Options()
                options.maxDimension = Settings.optimizeMaxDimension
                options.targetByteSize = Settings.optimizeTargetKB.map { $0 * 1024 }
                let backup: ((URL) throws -> Void)? = Settings.optimizeBackupToTrash
                    ? Self.moveToTrash : nil
                let result = try ImageOptimizer.optimize(url, options: options, backup: backup)
                totalBefore += result.originalSize
                totalAfter += result.skipped ? result.originalSize : result.optimizedSize
                if result.skipped {
                    lines.append("\(url.lastPathComponent)：\(L10n.optimizeNoChange)")
                } else {
                    shrunk += 1
                    let percent = 100 * result.savedBytes / max(result.originalSize, 1)
                    lines.append(L10n.optimizeLine(
                        url.lastPathComponent,
                        ByteCountFormatter.string(fromByteCount: Int64(result.originalSize), countStyle: .file),
                        ByteCountFormatter.string(fromByteCount: Int64(result.optimizedSize), countStyle: .file),
                        percent))
                }
            }
            if shrunk == 0 {
                job.info(L10n.nothingShrunk(targets.count))
            }
            let saved = max(totalBefore - totalAfter, 0)
            let savedText = ByteCountFormatter.string(fromByteCount: Int64(saved), countStyle: .file)
            job.notice(L10n.shrunkNotice(shrunk, targets.count, savedText))
            let shown = lines.prefix(5).joined(separator: "\n")
            let rest = lines.count > 5 ? "\n" + L10n.moreImages(lines.count - 5) : ""
            self.reportResult?(L10n.optimizeDone(shrunk, targets.count, savedText) + "\n" + shown + rest)
        } completion: {
            completion?()
        }
    }

    /// Extraction for non-ZIP formats (tar family, 7z, RAR, LZH…).
    /// Same guarantees as the ZIP path: budgets, no overwrites, quarantine.
    private func extractNonZip(_ archives: [URL], completion: (() -> Void)? = nil) {
        run(panelTitle: L10n.extract,
            panelLabel: archives.first?.lastPathComponent ?? "") { job in
            var failures: [String] = []
            var extractedNames: [String] = []
            for archive in archives {
                if job.isCancelled { throw DizunError.cancelled }
                job.update(archive.lastPathComponent)
                do {
                    var options = LibarchiveArchive.ExtractOptions()
                    options.isCancelled = { job.isCancelled }
                    let outcome = try LibarchiveArchive.extract(url: archive, options: options)
                    if !outcome.skippedSpecial.isEmpty {
                        job.notice("スキップしたリンク等: \(outcome.skippedSpecial.count)件")
                    }
                    if !outcome.renamedDuplicates.isEmpty {
                        let pairs = outcome.renamedDuplicates
                            .prefix(3).map { "\($0.original) → \($0.chosen)" }
                        job.notice("名前の衝突を回避: " + pairs.joined(separator: "、")
                            + (outcome.renamedDuplicates.count > 3
                               ? " ほか\(outcome.renamedDuplicates.count - 3)件" : ""))
                    }
                    if !outcome.quarantineFailures.isEmpty {
                        job.notice("quarantine未適用: \(outcome.quarantineFailures.count)件")
                    }
                    let listing = try LibarchiveArchive.list(url: archive)
                    let top = Set(listing.entries.compactMap { entry -> String? in
                        PathSafety.sanitize(entry.rawName)?.first
                    })
                    let revealDir = outcome.created.first.flatMap { c in
                        URL(fileURLWithPath: c).deletingLastPathComponent()
                    } ?? archive.deletingLastPathComponent()
                    job.reveal(top.isEmpty ? [revealDir] : [revealDir])
                    extractedNames.append(contentsOf: Array(top))
                } catch {
                    if archives.count == 1 { throw error }
                    failures.append("\(archive.lastPathComponent): \(error)")
                }
            }
            if !failures.isEmpty { job.alert(failures.joined(separator: "\n")) }
            let names = extractedNames.prefix(3).joined(separator: lang.isEN ? ", " : "、")
            if !names.isEmpty {
                self.reportResult?(L10n.extractionDone(names, more: extractedNames.count - 3))
            }
        } completion: {
            completion?()
        }
    }

    /// Synchronous move into the user's Trash. NSWorkspace.recycle is
    /// asynchronous — combined with a swap it can race and recycle the
    /// *replacement* file, so DIZUN moves the original itself (a same-volume
    /// rename; Finder's "Put Back" is not available for these).
    static func moveToTrash(_ url: URL) throws {
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var target = trash.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let variant = ext.isEmpty ? "\(name) (\(n))" : "\(name) (\(n)).\(ext)"
            target = trash.appendingPathComponent(variant)
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
    }

    func compress(files: [URL], mode: CompressMode = .fromSettings,
                  format: ArchiveFormat = .zip,
                  completion: (() -> Void)? = nil) {
        // Non-ZIP formats go through the vendored libarchive writer; the
        // password prompt below is a ZIP-only concern.
        if format != .zip {
            run(panelTitle: L10n.compressTitle,
                panelLabel: files.first?.lastPathComponent ?? "") { job in
                let destination = try Self.archiveDestination(for: files, format: format)
                job.update(destination.lastPathComponent)
                let outcome = try LibarchiveWriter.pack(files, to: destination, format: format)
                var note = ""
                if !outcome.skippedSpecial.isEmpty {
                    note = "スキップしたリンク等: \(outcome.skippedSpecial.count)件"
                }
                job.notice(note)
                job.reveal([destination])
                self.reportResult?(L10n.archiveDone(
                    destination.lastPathComponent,
                    files: outcome.entryCount,
                    size: ByteCountFormatter.string(fromByteCount: Int64(outcome.totalBytes),
                                                    countStyle: .file)) + (note.isEmpty ? "" : "\n" + note))
            } completion: {
                completion?()
            }
            return
        }
        // The password is asked per job and never stored.
        var encryption = ZipWriter.Encryption.none
        switch mode {
        case .plain:
            break
        case .encrypted:
            guard let password = requestPassword?(L10n.setPasswordTitle(false), true) else {
                completion?()
                return
            }
            encryption = .aes256(password: password)
        case .fromSettings:
            switch Settings.compressEncryptionKind {
            case .none:
                break
            case .aes256:
                guard let password = requestPassword?(L10n.setPasswordTitle(false), true) else {
                    completion?()
                    return
                }
                encryption = .aes256(password: password)
            case .zipCrypto:
                guard let password = requestPassword?(L10n.setPasswordTitle(true), true) else {
                    completion?()
                    return
                }
                encryption = .zipCrypto(password: password)
            }
        }
        run(panelTitle: L10n.compressTitle,
            panelLabel: files.first?.lastPathComponent ?? "") { job in
            let destination = try Self.archiveDestination(for: files)
            job.update(destination.lastPathComponent)
            var options = Packer.Options()
            options.nameEncoding = Settings.compressEncoding
            options.encryption = encryption
            let result = try Packer.pack(files, to: destination,
                                         options: options,
                                         progress: { job.update($0) },
                                         shouldCancel: { job.isCancelled })
            job.notice(Self.notice(for: result))
            job.reveal([destination])
        } completion: {
            completion?()
        }
    }

    /// Finder's naming rule: one item → "name.<ext>", several → "Archive.<ext>",
    /// uniquified against the destination folder. `Packer` still refuses to
    /// overwrite whatever appears between this check and the create.
    static func archiveDestination(for files: [URL], format: ArchiveFormat = .zip) throws -> URL {
        guard let first = files.first else {
            throw DizunError.ioFailure("対象がありません")
        }
        let folder = first.deletingLastPathComponent()
        let stem = Settings.archiveBaseName
            ?? (files.count == 1
                ? first.deletingPathExtension().lastPathComponent
                : "Archive")
        // ZIP keeps the plain extension; compound formats keep their suffix.
        let suffix = "." + (format.commonExtensions.first ?? "zip")
        var candidate = folder.appendingPathComponent(stem + suffix)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(n)\(suffix)")
            n += 1
        }
        return candidate
    }

    private static func notice(for result: Unpacker.Result) -> String {
        var parts: [String] = []
        if !result.skippedJunk.isEmpty {
            parts.append("除外したmacOSファイル: \(result.skippedJunk.count)件")
        }
        if !result.skippedSymlinks.isEmpty {
            parts.append("スキップしたリンク: \(result.skippedSymlinks.count)件")
        }
        if !result.skippedUnsafe.isEmpty {
            parts.append("安全のため除外: \(result.skippedUnsafe.count)件")
        }
        if !result.renamedDuplicates.isEmpty {
            parts.append("名前の衝突を回避: \(result.renamedDuplicates.count)件")
        }
        return parts.joined(separator: "・")
    }

    private static func notice(for result: Packer.Result) -> String {
        var parts: [String] = []
        if !result.skippedSymlinks.isEmpty {
            parts.append("スキップしたリンク: \(result.skippedSymlinks.count)件")
        }
        if !result.excludedJunk.isEmpty {
            parts.append("除外したmacOSファイル: \(result.excludedJunk.count)件")
        }
        return parts.joined(separator: "・")
    }

    // MARK: - Job plumbing

    private func run(panelTitle: String, panelLabel: String,
                     work: @escaping (Job) throws -> Void,
                     completion: @escaping () -> Void) {
        guard !busy else {
            DispatchQueue.main.async {
                WorkPanel.shared.flashBusy()
            }
            completion()
            return
        }
        busy = true
        let job = Job()
        DispatchQueue.main.async {
            WorkPanel.shared.begin(title: panelTitle, label: panelLabel) { job.cancel() }
        }
        queue.async { [self] in
            do {
                try work(job)
            } catch let error as DizunError where error == .cancelled {
                // Quiet finish — the panel already said "cancelled".
            } catch {
                job.alert("失敗しました:\n\(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                WorkPanel.shared.end()
                self.busy = false
                completion()
            }
        }
    }

    /// Handle given to job bodies. UI hops are fire-and-forget; the alert is
    /// synchronous so completion (and app termination) waits for the user.
    final class Job {
        private let flag = CancelFlag()
        var isCancelled: Bool { flag.isSet }
        fileprivate func cancel() { flag.set() }

        func update(_ stage: String) {
            DispatchQueue.main.async { WorkPanel.shared.updateLabel(stage) }
        }

        func notice(_ text: String) {
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { WorkPanel.shared.setNotice(text) }
        }

        func reveal(_ urls: [URL]) {
            guard !urls.isEmpty,
                  ProcessInfo.processInfo.environment["DIZUN_NO_REVEAL"] == nil else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }

        func alert(_ message: String) {
            DispatchQueue.main.sync {
                WorkPanel.shared.showError(message)
            }
        }

        /// Informational report; modal so completion (and termination) waits.
        func info(_ message: String) {
            DispatchQueue.main.sync {
                WorkPanel.shared.flash(message: message)
            }
        }
    }

    /// Thread-safe cancellation shared between the cancel button and the job.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
    }
}
