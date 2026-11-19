import AppKit
import DizunCore
import DizunImage
import Foundation

/// Runs compression/extraction jobs on a background queue and reports to the
/// progress panel. Alerts are synchronous so one-shot termination never
/// overtakes them.
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

    /// Drop / open heuristic: only .zips → extract, anything else → compress.
    /// A lone ZIP is routed to the preview first when one is configured.
    func performAutomatic(urls: [URL], completion: @escaping () -> Void) {
        let images = urls.filter(ImageOptimizer.isSupported)
        if images.count == urls.count, !images.isEmpty {
            optimizeImages(images, completion: completion)
            return
        }
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        if zips.count == urls.count, !zips.isEmpty {
            if zips.count == 1, !Settings.instantExtract, let openPreview {
                openPreview(zips[0])
                return
            }
            extractAll(archives: zips, completion: completion)
        } else {
            compress(files: urls, completion: completion)
        }
    }

    func extractAll(archives: [URL], forcedEncoding: NameEncoding? = nil,
                    password: String? = nil,
                    completion: (() -> Void)? = nil) {
        // Ask for the password up front — the engine refuses to touch the
        // disk without one, and prompting before the panel starts keeps the
        // retry clean.
        var password = password
        if password == nil {
            for archive in archives {
                guard let reader = try? ZipReader(url: archive) else { continue }
                if reader.entries.contains(where: { $0.isEncrypted && !$0.isDirectory }) {
                    guard let supplied = requestPassword?(
                        "「\(archive.lastPathComponent)」はパスワードで保護されています", false) else {
                        completion?()
                        return
                    }
                    password = supplied
                    break
                }
            }
        }
        run(panelTitle: "解凍",
            panelLabel: archives.first?.lastPathComponent ?? "") { job in
            var revealed = false
            var failures: [String] = []
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
                } catch {
                    if archives.count == 1 { throw error }
                    failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { job.alert(failures.joined(separator: "\n")) }
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
        run(panelTitle: "画像最適化",
            panelLabel: targets.first?.lastPathComponent ?? "") { job in
            var totalBefore = 0
            var totalAfter = 0
            var shrunk = 0
            for (index, url) in targets.enumerated() {
                if job.isCancelled { throw DizunError.cancelled }
                job.update("（\(index + 1)/\(targets.count)）\(url.lastPathComponent)")
                var options = ImageOptimizer.Options()
                options.maxDimension = Settings.optimizeMaxDimension
                let backup: ((URL) throws -> Void)? = Settings.optimizeBackupToTrash ? { original in
                    var failure: Error?
                    DispatchQueue.main.sync {
                        do {
                            try NSWorkspace.shared.recycle([original], completionHandler: nil)
                        } catch {
                            failure = error
                        }
                    }
                    if let failure { throw failure }
                } : nil
                let result = try ImageOptimizer.optimize(url, options: options, backup: backup)
                totalBefore += result.originalSize
                totalAfter += result.skipped ? result.originalSize : result.optimizedSize
                if !result.skipped { shrunk += 1 }
            }
            let saved = max(totalBefore - totalAfter, 0)
            let savedText = ByteCountFormatter.string(fromByteCount: Int64(saved), countStyle: .file)
            job.notice("\(shrunk)/\(targets.count)枚を縮小（\(savedText) 節約）")
            job.reveal([])
        } completion: {
            completion?()
        }
    }

    func compress(files: [URL], mode: CompressMode = .fromSettings,
                  completion: (() -> Void)? = nil) {
        // The password is asked per job and never stored.
        var encryption = ZipWriter.Encryption.none
        switch mode {
        case .plain:
            break
        case .encrypted:
            guard let password = requestPassword?("暗号化パスワードを設定（AES-256）", true) else {
                completion?()
                return
            }
            encryption = .aes256(password: password)
        case .fromSettings:
            switch Settings.compressEncryptionKind {
            case .none:
                break
            case .aes256:
                guard let password = requestPassword?("暗号化パスワードを設定（AES-256）", true) else {
                    completion?()
                    return
                }
                encryption = .aes256(password: password)
            case .zipCrypto:
                guard let password = requestPassword?(
                    "暗号化パスワードを設定（ZipCrypto: 旧方式のため保護は弱いです）", true) else {
                    completion?()
                    return
                }
                encryption = .zipCrypto(password: password)
            }
        }
        run(panelTitle: "圧縮",
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

    /// Finder's naming rule: one item → "name.zip", several → "Archive.zip",
    /// uniquified against the destination folder. `Packer` still refuses to
    /// overwrite whatever appears between this check and the create.
    static func archiveDestination(for files: [URL]) throws -> URL {
        guard let first = files.first else {
            throw DizunError.ioFailure("対象がありません")
        }
        let folder = first.deletingLastPathComponent()
        let stem = files.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : "Archive"
        var candidate = folder.appendingPathComponent(stem + ".zip")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(n).zip")
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
                WorkPanel.shared.flash(message: "前の処理が終わってから実行してください")
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
