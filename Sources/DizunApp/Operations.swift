import AppKit
import DizunCore
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

    /// Drop / open heuristic: only .zips → extract, anything else → compress.
    func performAutomatic(urls: [URL], completion: @escaping () -> Void) {
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        if zips.count == urls.count, !zips.isEmpty {
            extractAll(archives: zips, completion: completion)
        } else {
            compress(files: urls, completion: completion)
        }
    }

    func extractAll(archives: [URL], completion: (() -> Void)? = nil) {
        run(panelTitle: "解凍",
            panelLabel: archives.first?.lastPathComponent ?? "") { job in
            var revealed = false
            var failures: [String] = []
            for (index, archive) in archives.enumerated() {
                if job.isCancelled { throw DizunError.cancelled }
                let prefix = archives.count > 1 ? "（\(index + 1)/\(archives.count)）" : ""
                job.update("\(archive.lastPathComponent)\(prefix)")
                do {
                    let result = try Unpacker.unpack(zipURL: archive,
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

    func compress(files: [URL], completion: (() -> Void)? = nil) {
        run(panelTitle: "圧縮",
            panelLabel: files.first?.lastPathComponent ?? "") { job in
            let destination = try Self.archiveDestination(for: files)
            job.update(destination.lastPathComponent)
            let result = try Packer.pack(files, to: destination,
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
