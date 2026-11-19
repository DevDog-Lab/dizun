import Foundation

/// Extraction with the safety rules from SPEC §6: zip-slip guard, symlinks
/// skipped, existing files never overwritten (unique names instead), a
/// pre-flight size budget, cancellation with cleanup of exactly what this run
/// created, and quarantine propagation. Normal extraction never mutates
/// extracted bytes.
public enum Unpacker {
    /// When to wrap extracted content in a folder named after the ZIP.
    public enum FolderPolicy: Sendable, Equatable {
        case onlyMultipleTopLevel
        case always
        case never
    }

    public struct Options: Sendable {
        /// Destination directory; nil means the ZIP's own directory.
        public var destination: URL?
        /// Force the name encoding for entries without the UTF-8 flag.
        public var forcedEncoding: NameEncoding?
        /// Password for encrypted entries; nil on an archive that needs one
        /// fails before anything is written (`DizunError.passwordRequired`).
        public var password: String?
        public var folderPolicy: FolderPolicy = .onlyMultipleTopLevel
        public var limits: ExtractionLimits = ExtractionLimits()
        /// Skip macOS bookkeeping entries (`__MACOSX/`, `.DS_Store`, `._*`)
        /// on extraction — what a Windows user would see as garbage. They are
        /// reported in `Result.skippedJunk`, never silently dropped.
        public var skipMacJunk = true
        public init(destination: URL? = nil,
                    forcedEncoding: NameEncoding? = nil,
                    password: String? = nil,
                    folderPolicy: FolderPolicy = .onlyMultipleTopLevel,
                    limits: ExtractionLimits = ExtractionLimits(),
                    skipMacJunk: Bool = true) {
            self.destination = destination
            self.forcedEncoding = forcedEncoding
            self.password = password
            self.folderPolicy = folderPolicy
            self.limits = limits
            self.skipMacJunk = skipMacJunk
        }
    }

    public struct Result: Sendable {
        public var root: URL
        public var extractedTopItems: [URL]
        public var createdWrapper: Bool
        public var extractedFiles: Int
        public var extractedDirectories: Int
        /// Entries whose paths would escape the destination — skipped.
        public var skippedUnsafe: [String]
        /// Symlink entries skipped by policy.
        public var skippedSymlinks: [String]
        /// Colliding entries extracted under a numbered name.
        public var renamedDuplicates: [(original: String, chosen: String)]
        /// macOS bookkeeping entries skipped by `skipMacJunk`.
        public var skippedJunk: [String]
        public var detectedEncoding: NameEncoding
        /// Items the quarantine attribute could not be set on — reported,
        /// never swallowed (Gatekeeper visibility).
        public var quarantineFailures: [String]
    }

    public enum Failure: Error, Equatable {
        case emptyArchive
        case destinationNotADirectory(String)
        case insufficientSpace(required: UInt64, available: UInt64)
    }

    /// Free bytes on the destination volume, nil when unavailable. The
    /// important-usage key answers 0 on network mounts — that must read as
    /// "no answer", not "full disk", so it falls through to the plain figure.
    static func freeSpace(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                      .volumeAvailableCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage
        let plain = values?.volumeAvailableCapacity
        var candidates: [UInt64] = []
        if let important, important > 0 { candidates.append(UInt64(important)) }
        if let plain, plain >= 0 { candidates.append(UInt64(plain)) }
        return candidates.max()
    }

    /// Extract `zipURL`. `shouldCancel` is polled between entries; on
    /// cancellation or failure everything this run created is removed and the
    /// error propagates.
    public static func unpack(zipURL: URL,
                              options: Options = Options(),
                              progress: ((String) -> Void)? = nil,
                              shouldCancel: (() -> Bool)? = nil) throws -> Result {
        let reader = try ZipReader(url: zipURL, limits: options.limits)
        let destBase = options.destination ?? zipURL.deletingLastPathComponent()

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destBase.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw Failure.destinationNotADirectory(destBase.path)
            }
        }
        // The destination itself is created only after every fail-fast check
        // has passed — a password prompt or refusal must find no debris.

        // Plan phase: nothing is written until every entry has a safe,
        // collision-free target.
        var skippedUnsafe: [String] = []
        var skippedSymlinks: [String] = []
        var skippedJunk: [String] = []
        var renamedDuplicates: [(original: String, chosen: String)] = []
        var work: [(entry: ZipEntry, components: [String])] = []
        var claimedPaths = Set<String>()
        let forced = options.forcedEncoding
        let listing = forced.map { reader.entriesDecoded(as: $0) } ?? reader.entries

        for entry in listing {
            guard var components = PathSafety.sanitize(entry.name) else {
                skippedUnsafe.append(entry.name)
                continue
            }
            if entry.isSymlink {
                skippedSymlinks.append(entry.name)
                continue
            }
            if options.skipMacJunk && JunkFilter.isJunkPath(components) {
                skippedJunk.append(entry.name)
                continue
            }
            // Directory entries legitimately repeat; only files collide.
            if !entry.isDirectory {
                let originalPath = components.joined(separator: "/")
                if claimedPaths.contains(PathSafety.collisionKey(components)) {
                    let leaf = components[components.count - 1]
                    let stem = (leaf as NSString).deletingPathExtension
                    let ext = (leaf as NSString).pathExtension
                    var n = 2
                    repeat {
                        components[components.count - 1] =
                            ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                        n += 1
                    } while claimedPaths.contains(PathSafety.collisionKey(components))
                    renamedDuplicates.append((original: originalPath,
                                              chosen: components[components.count - 1]))
                }
                claimedPaths.insert(PathSafety.collisionKey(components))
            }
            work.append((entry, components))
        }
        guard !work.isEmpty else { throw Failure.emptyArchive }

        // Encrypted content needs a password before anything is written, so
        // a retry after the prompt finds no debris (SPEC §6).
        if options.password == nil,
           work.contains(where: { $0.entry.isEncrypted && !$0.entry.isDirectory }) {
            throw DizunError.passwordRequired
        }

        // Pre-flight budget: fail before touching the disk (SPEC §6).
        let required = reader.declaredTotalSize
        guard required <= options.limits.maxTotalUncompressed else {
            throw DizunError.limitExceeded(
                "declared total \(required) bytes over the archive cap")
        }
        if let available = freeSpace(at: destBase) ?? freeSpace(at: destBase.deletingLastPathComponent()) {
            let budget = available > options.limits.spaceMargin
                ? available - options.limits.spaceMargin : 0
            guard required <= budget else {
                throw Failure.insufficientSpace(required: required, available: available)
            }
        }
        try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)

        let topNames = Set(work.map { $0.components[0] })
        let wrap: Bool
        switch options.folderPolicy {
        case .always: wrap = true
        case .never: wrap = false
        case .onlyMultipleTopLevel: wrap = topNames.count > 1
        }

        let base: URL
        let root: URL
        var topItems: [URL] = []
        var renames: [String: String] = [:]
        var owned = PathUtil.OwnedItems()
        if wrap {
            let stem = zipURL.deletingPathExtension().lastPathComponent
            let wrapper = destBase.appendingPathComponent(
                PathUtil.uniqueName(stem.isEmpty ? "Archive" : stem) {
                    PathUtil.somethingExists(at: destBase.appendingPathComponent($0))
                })
            try PathUtil.createDirectoryExclusively(at: wrapper)
            owned.adopt(wrapper)
            base = wrapper
            root = wrapper
            topItems = [wrapper]
        } else {
            var assigned = Set<String>()
            for top in topNames.sorted() {
                let final = PathUtil.uniqueName(top) { candidate in
                    assigned.contains(PathSafety.collisionKey([candidate]))
                        || PathUtil.somethingExists(at: destBase.appendingPathComponent(candidate))
                }
                assigned.insert(PathSafety.collisionKey([final]))
                if final != top { renames[top] = final }
                topItems.append(destBase.appendingPathComponent(final))
            }
            base = destBase
            root = topItems.count == 1 ? topItems[0] : destBase
        }

        let quarantine = Quarantine.attribute(of: zipURL)
        var quarantineFailures: [String] = []
        func applyQuarantine(to url: URL, named name: String) {
            guard let quarantine else { return }
            if !Quarantine.apply(quarantine, to: url) {
                quarantineFailures.append(name)
            }
        }

        var files = 0
        var directories = 0
        func extractOne(_ entry: ZipEntry, _ rawComponents: [String]) throws {
            var components = rawComponents
            if let renamed = renames[components[0]] { components[0] = renamed }
            let entryPath = rawComponents.joined(separator: "/")
            progress?(entryPath)
            let target = components.reduce(base) { $0.appendingPathComponent($1) }

            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                directories += 1
            } else {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let out = try PathUtil.createFileExclusively(at: target)
                do {
                    try reader.extract(entry, password: options.password) { chunk in
                        try out.handle.write(contentsOf: chunk)
                    }
                    out.close()
                } catch {
                    out.close()
                    throw error
                }
                files += 1
            }

            var attrs: [FileAttributeKey: Any] = [:]
            if let mtime = entry.modificationDate {
                attrs[.modificationDate] = mtime
            }
            if let mode = entry.unixMode {
                // Keep owner read/write so extraction never locks anyone out.
                attrs[.posixPermissions] = NSNumber(value: sanitizeMode(mode, isDirectory: entry.isDirectory))
            }
            if !attrs.isEmpty {
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: target.path)
            }
            applyQuarantine(to: target, named: entryPath)
        }

        do {
            for (entry, components) in work {
                if shouldCancel?() == true { throw DizunError.cancelled }
                try extractOne(entry, components)
            }
            if wrap { applyQuarantine(to: base, named: base.lastPathComponent) }
        } catch {
            owned.removeAll()
            throw error
        }

        return Result(root: root,
                      extractedTopItems: topItems,
                      createdWrapper: wrap,
                      extractedFiles: files,
                      extractedDirectories: directories,
                      skippedUnsafe: skippedUnsafe,
                      skippedSymlinks: skippedSymlinks,
                      renamedDuplicates: renamedDuplicates,
                      skippedJunk: skippedJunk,
                      detectedEncoding: forced ?? reader.detectedEncoding,
                      quarantineFailures: quarantineFailures)
    }

    /// Archive-requested permissions, masked to rwx bits with owner access
    /// forced on so extraction never locks anyone out.
    static func sanitizeMode(_ mode: UInt16, isDirectory: Bool) -> UInt16 {
        var result = mode & 0o777
        result |= isDirectory ? 0o700 : 0o600
        return result
    }
}
