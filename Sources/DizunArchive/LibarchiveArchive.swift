import CArchive
import DizunCore
import Foundation

/// Reading and writing non-ZIP archives through the vendored libarchive.
///
/// Safety contract (mirrors DizunCore.Unpacker so every format gets the
/// same guarantees): content-sniffed formats are registered one at a time
/// — never `support_format_all` — entry data is copied out of libarchive
/// immediately, paths go through `PathSafety.sanitize`, only regular
/// files and directories are restored, existing files are never
/// overwritten (unique names instead), and extraction enforces the same
/// entry/size/space budgets. The final write happens on the Swift side
/// (`archive_read_extract` is never used).
public enum LibarchiveArchive {

    // MARK: - Models

    public enum EntryKind: Sendable, Equatable {
        case file
        case directory
        /// Symlinks, hardlinks, devices, FIFOs…: skipped, reported.
        case special(String)
    }

    /// Plain-value snapshot of a libarchive entry. The C entry pointer is
    /// not kept past the header read.
    public struct Entry: Sendable, Equatable {
        public var rawName: String
        public var kind: EntryKind
        /// Declared uncompressed size; nil when the container does not say.
        public var declaredSize: UInt64?
        public var isEncrypted: Bool
        init(rawName: String, kind: EntryKind, declaredSize: UInt64?, isEncrypted: Bool) {
            self.rawName = rawName
            self.kind = kind
            self.declaredSize = declaredSize
            self.isEncrypted = isEncrypted
        }
    }

    public struct Listing: Sendable {
        public var format: ArchiveFormat
        public var entries: [Entry]
        /// Non-fatal notes collected while walking the archive
        /// (e.g. unsupported members). Never shown as success.
        public var warnings: [String]
        init(format: ArchiveFormat, entries: [Entry], warnings: [String]) {
            self.format = format
            self.entries = entries
            self.warnings = warnings
        }
    }

    public struct ExtractOutcome: Sendable {
        public var created: [String]
        public var skippedJunk: [String]
        public var skippedSpecial: [String]
        /// Entries diverted to "name 2"… because the name already existed
        /// on disk (or earlier in this run). Existing items were untouched.
        public var renamedDuplicates: [(original: String, chosen: String)]
        public var totalBytesWritten: UInt64
        public var quarantineFailures: [String]
        init() {
            created = []; skippedJunk = []; skippedSpecial = []
            renamedDuplicates = []
            totalBytesWritten = 0; quarantineFailures = []
        }
    }

    public enum Failure: Error, Equatable {
        /// libarchive refused the input.
        case cannotOpen(String)
        /// Budget or policy guard tripped: nothing is finalized.
        case safetyLimit(String)
        /// Fatal mid-archive error (corrupt data, missing codec…).
        case corrupt(String)
        /// Encrypted archive family DIZUN does not open.
        case encrypted(String)
        case cancelled
    }

    public struct ExtractOptions: Sendable {
        public var destination: URL?
        public var limits: ExtractionLimits
        public var skipMacJunk: Bool
        public var isCancelled: @Sendable () -> Bool
        public init(destination: URL? = nil,
                    limits: ExtractionLimits = ExtractionLimits(),
                    skipMacJunk: Bool = true,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) {
            self.destination = destination
            self.limits = limits
            self.skipMacJunk = skipMacJunk
            self.isCancelled = isCancelled
        }
    }

    // MARK: - Registration (explicit, per the adopted architecture)

    /// Register exactly the format the detector chose.
    static func registerFormat(_ format: ArchiveFormat, _ a: OpaquePointer) {
        switch format {
        case .tar, .tarGz, .tarBz2, .tarXz:
            archive_read_support_format_tar(a)
        case .sevenZ:
            archive_read_support_format_7zip(a)
        case .rar:
            archive_read_support_format_rar(a)
        case .rar5:
            archive_read_support_format_rar5(a)
        case .lzh:
            archive_read_support_format_lha(a)
        case .gzipStream, .bzip2Stream, .xzStream:
            archive_read_support_format_raw(a)
        case .zip:
            break  // ZIP never comes through this adapter.
        }
        switch format {
        case .tarGz, .gzipStream: archive_read_support_filter_gzip(a)
        case .tarBz2, .bzip2Stream: archive_read_support_filter_bzip2(a)
        case .tarXz, .xzStream: archive_read_support_filter_xz(a)
        default: archive_read_support_filter_none(a)
        }
    }

    /// Resolve a compressed stream: `.gz`/`.bz2`/`.xz` whose payload is a
    /// tar becomes the matching compound format; otherwise it stays a
    /// single-payload stream.
    public static func resolveStream(_ format: ArchiveFormat, url: URL) -> ArchiveFormat {
        guard let wrapped = streamWrapper(format) else { return format }
        // Peek at the first block of the decompressed payload.
        guard let payload = decompressPrefix(url, format: format, count: 512) else { return format }
        var probe = [UInt8](payload)
        if probe.count < 512 { probe += [UInt8](repeating: 0, count: 512 - probe.count) }
        if FormatDetector.looksLikeTarChecksum(probe)
            || probe.count >= 262 && Array(probe[257..<262]) == Array("ustar".utf8) {
            return wrapped
        }
        return format
    }

    /// Sniff, then unwrap compressed streams whose payload is a tar.
    static func resolve(url: URL, hint: ArchiveFormat?) throws -> ArchiveFormat? {
        guard let detected = hint ?? FormatDetector.detect(url: url) else { return nil }
        return resolveStream(detected, url: url)
    }

    static func streamWrapper(_ format: ArchiveFormat) -> ArchiveFormat? {
        switch format {
        case .gzipStream: .tarGz
        case .bzip2Stream: .tarBz2
        case .xzStream: .tarXz
        default: nil
        }
    }

    // MARK: - Listing

    public static func list(url: URL, format hint: ArchiveFormat? = nil) throws -> Listing {
        dizun_archive_use_utf8_locale()
        let format = try resolve(url: url, hint: hint)
        guard let format, format != .zip else {
            throw Failure.cannotOpen("unrecognized archive")
        }
        guard let a = archive_read_new() else { throw Failure.cannotOpen("alloc") }
        defer { archive_read_free(a) }
        registerFormat(format, a)
        try open(a, url: url)
        var entries: [Entry] = []
        var warnings: [String] = []
        while true {
            var entryPtr: OpaquePointer? = nil
            let r = archive_read_next_header(a, &entryPtr)
            if r == ARCHIVE_EOF { break }
            if r == ARCHIVE_FATAL || r == ARCHIVE_FAILED {
                throw interpret(archive_error_string(a), fallback: "read error")
            }
            if r == ARCHIVE_WARN {
                warnings.append(String(cString: archive_error_string(a)))
            }
            guard let entryPtr else { break }
            entries.append(snapshot(entryPtr))
            if entries.count > 10_000 { throw Failure.safetyLimit("too many entries") }
            if entries.last?.isEncrypted == true {
                throw Failure.encrypted("encrypted member")
            }
        }
        return Listing(format: format, entries: entries, warnings: warnings)
    }

    // MARK: - Extraction

    public static func extract(url: URL, options: ExtractOptions = ExtractOptions()) throws -> ExtractOutcome {
        dizun_archive_use_utf8_locale()
        let format = try resolve(url: url, hint: nil)
        guard let format, format != .zip else {
            throw Failure.cannotOpen("unrecognized archive")
        }
        let listing = try list(url: url, format: format)

        // Pre-flight budgets over declared sizes (unknown sizes read as 0
        // but the written-byte counter still enforces the ceiling live).
        var declaredTotal: UInt64 = 0
        for e in listing.entries {
            if case .file = e.kind {
                let size = e.declaredSize ?? 0
                if size > options.limits.maxEntrySize {
                    throw Failure.safetyLimit("entry exceeds single-file limit")
                }
                declaredTotal &+= size
            }
        }
        if listing.entries.count > options.limits.maxEntries {
            throw Failure.safetyLimit("too many entries")
        }
        if declaredTotal > options.limits.maxTotalUncompressed {
            throw Failure.safetyLimit("archive exceeds total size limit")
        }
        let destination = try destinationDirectory(url: url, option: options.destination)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try safeCreateDirectory(destination)
        }

        guard let a = archive_read_new() else { throw Failure.cannotOpen("alloc") }
        defer { archive_read_free(a) }
        registerFormat(format, a)
        try open(a, url: url)

        var outcome = ExtractOutcome()
        var usedNames: Set<String> = []
        var owned: [URL] = []
        // Folder-level separation: a top-level name that already exists
        // on disk moves the *whole* subtree to "name 2", instead of
        // letting inner files mingle with the existing folder's files.
        var topRemap: [String: String] = [:]
        for entry in listing.entries {
            guard let components = PathSafety.sanitize(entry.rawName),
                  let first = components.first else { continue }
            let key = PathSafety.collisionKey([first])
            if topRemap[key] != nil { continue }
            if !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(first).path) {
                topRemap[key] = first
                continue
            }
            var index = 2
            while FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("\(first) \(index)").path) {
                index += 1
            }
            let chosen = "\(first) \(index)"
            topRemap[key] = chosen
            outcome.renamedDuplicates.append((first, chosen))
        }
        func remapped(_ components: [String]) -> [String] {
            guard let first = components.first,
                  let mapped = topRemap[PathSafety.collisionKey([first])] else {
                return components
            }
            return [mapped] + components.dropFirst()
        }
        let quarantine = Quarantine.attribute(of: url)
        do {
            try withSubdirectoryIfNeeded(listing, destination: destination) { root in
                var entryPtr: OpaquePointer? = nil
                while true {
                    if options.isCancelled() { throw Failure.cancelled }
                    let r = archive_read_next_header(a, &entryPtr)
                    if r == ARCHIVE_EOF { break }
                    if r == ARCHIVE_FATAL || r == ARCHIVE_FAILED {
                        throw interpret(archive_error_string(a), fallback: "read error")
                    }
                    guard let entryPtr else { break }
                    let entry = snapshot(entryPtr)
                    guard let rawComponents = PathSafety.sanitize(entry.rawName) else {
                        throw Failure.safetyLimit("unsafe path: \(entry.rawName)")
                    }
                    let components = remapped(rawComponents)
                    if options.skipMacJunk && JunkFilter.isJunkPath(components) {
                        outcome.skippedJunk.append(entry.rawName)
                        archive_read_data_skip(a)
                        continue
                    }
                    switch entry.kind {
                    case .directory:
                        let dir = uniqueURL(root: root, components: components,
                                            used: &usedNames, isDirectory: true,
                                            renamed: &outcome.renamedDuplicates)
                        try safeCreateDirectory(dir)
                        try owned.appendingUniqueCreated(dir)
                        outcome.created.append(components.joined(separator: "/"))
                    case .file:
                        var written: UInt64 = 0
                        let fileURL = uniqueURL(root: root, components: components,
                                                used: &usedNames, isDirectory: false,
                                                renamed: &outcome.renamedDuplicates)
                        // Some containers (7z) list files before their
                        // directories; create missing parents on demand and
                        // keep them on the cleanup ledger.
                        let missingParent = fileURL.deletingLastPathComponent()
                        if !FileManager.default.fileExists(atPath: missingParent.path) {
                            owned.append(contentsOf: try safeCreateDirectory(missingParent))
                        }
                        try Data.writeStreaming(to: fileURL) { sink in
                            while true {
                                if options.isCancelled() { throw Failure.cancelled }
                                var buf: UnsafeRawPointer? = nil
                                var size: Int = 0; var offset: Int64 = 0
                                let rr = archive_read_data_block(a, &buf, &size, &offset)
                                if rr == ARCHIVE_EOF { break }
                                if rr != ARCHIVE_OK {
                                    throw interpret(archive_error_string(a), fallback: "data error")
                                }
                                guard let buf else { break }
                                written &+= UInt64(size)
                                if written > options.limits.maxEntrySize
                                    || outcome.totalBytesWritten + written > options.limits.maxTotalUncompressed {
                                    throw Failure.safetyLimit("budget exceeded while extracting")
                                }
                                try sink(Data(bytes: buf, count: size))
                            }
                        }
                        try owned.appendingUniqueCreated(fileURL)
                        outcome.created.append(components.joined(separator: "/"))
                        outcome.totalBytesWritten &+= written
                        if let quarantine {
                            if !Quarantine.apply(quarantine, to: fileURL) {
                                outcome.quarantineFailures.append(entry.rawName)
                            }
                        }
                    case .special(let why):
                        outcome.skippedSpecial.append("\(entry.rawName) (\(why))")
                        archive_read_data_skip(a)
                    }
                }
            }
        } catch {
            // Never leave partial output behind on failure/cancellation —
            // but never touch anything we did not create this run.
            for item in owned.reversed() { try? FileManager.default.removeItem(at: item) }
            throw error
        }
        return outcome
    }

    // MARK: - Helpers

    static func snapshot(_ entryPtr: OpaquePointer) -> Entry {
        let nameC = archive_entry_pathname(entryPtr)
        let name = nameC.map { String(cString: $0) } ?? ""
        let filetype = archive_entry_filetype(entryPtr)
        let kind: EntryKind
        switch filetype & 0o170000 {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000:
            let link = archive_entry_symlink(entryPtr).map { String(cString: $0) } ?? ""
            kind = .special("symlink: \(link)")
        case 0o110000: kind = .special("hardlink")
        default: kind = .special("special file type")
        }
        let size = archive_entry_size_is_set(entryPtr) != 0
            ? UInt64(archive_entry_size(entryPtr)) : nil
        let encrypted = archive_entry_is_encrypted(entryPtr) != 0
        return Entry(rawName: name, kind: kind, declaredSize: size, isEncrypted: encrypted)
    }

    static func open(_ a: OpaquePointer, url: URL) throws {
        let r = url.path.withCString { cPath in
            archive_read_open_filename(a, cPath, 1 << 16)
        }
        guard r == ARCHIVE_OK else {
            throw interpret(archive_error_string(a), fallback: "cannot open")
        }
    }


    /// Decompress at most `count` bytes of a gzip/bzip2/xz stream through
    /// libarchive's raw reader, purely to sniff what is inside.
    static func decompressPrefix(_ url: URL, format: ArchiveFormat, count: Int) -> Data? {
        guard let a = archive_read_new() else { return nil }
        defer { archive_read_free(a) }
        archive_read_support_format_raw(a)
        switch format {
        case .gzipStream: archive_read_support_filter_gzip(a)
        case .bzip2Stream: archive_read_support_filter_bzip2(a)
        case .xzStream: archive_read_support_filter_xz(a)
        default: return nil
        }
        guard url.path.withCString({ archive_read_open_filename(a, $0, 1 << 16) }) == ARCHIVE_OK else {
            return nil
        }
        var entryPtr: OpaquePointer? = nil
        guard archive_read_next_header(a, &entryPtr) == ARCHIVE_OK else { return nil }
        var out = Data(); out.reserveCapacity(count)
        while out.count < count {
            var buf: UnsafeRawPointer? = nil
            var size: Int = 0; var offset: Int64 = 0
            let r = archive_read_data_block(a, &buf, &size, &offset)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let buf else { return out.isEmpty ? nil : out }
            let take = min(Int(size), count - out.count)
            out.append(Data(bytes: buf, count: take))
            if take < Int(size) { break }
        }
        return out
    }

    static func interpret(_ message: UnsafePointer<CChar>?, fallback: String) -> Failure {
        let text = message.map { String(cString: $0) } ?? fallback
        let lowered = text.lowercased()
        if lowered.contains("password") || lowered.contains("encrypted")
            || lowered.contains("unsupported compression") && lowered.contains("7-Zip") {
            return .encrypted(text)
        }
        return .corrupt(text)
    }

    /// Destination folder: the archive's own directory unless overridden.
    /// Existing files are never overwritten; entries get unique names.
    static func destinationDirectory(url: URL, option: URL?) throws -> URL {
        if let option { return option }
        return url.deletingLastPathComponent()
    }

    /// Wrap in a folder named after the archive when it holds several
    /// top-level items (the Finder convention DizunCore.Unpacker uses).
    static func withSubdirectoryIfNeeded(_ listing: Listing,
                                         destination: URL,
                                         _ body: (URL) throws -> Void) throws {
        let topLevel = Set(listing.entries.compactMap { e -> String? in
            guard let safe = PathSafety.sanitize(e.rawName) else { return nil }
            return safe.first
        })
        if topLevel.count > 1 {
            var root = destination.appendingPathComponent(
                uniqueBaseName(for: destination, preferred: listingArchiveName(listing)))
            while FileManager.default.fileExists(atPath: root.path) {
                root = destination.appendingPathComponent(
                    uniqueBaseName(for: destination, preferred: listingArchiveName(listing)))
            }
            try safeCreateDirectory(root)
            defer { }  // keep the folder even on success-only paths; body handles content
            try body(root)
        } else {
            try body(destination)
        }
    }

    static func listingArchiveName(_ listing: Listing) -> String {
        listing.entries.first?.rawName.split(separator: "/").first.map(String.init)
            ?? "Archive"
    }

    static func uniqueBaseName(for directory: URL, preferred: String) -> String {
        var candidate = preferred
        var index = 2
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(preferred) \(index)"
            index += 1
        }
        return candidate
    }

    /// Case/NFC-insensitive unique destination, same rule as the ZIP
    /// engine: an entry never overwrites — not another entry of this job
    /// (`used`), and not anything already on disk. Existing folders and
    /// files push the new item to "name 2", "name 3"… instead of failing.
    /// Renames are recorded so the caller can report them.
    static func uniqueURL(root: URL, components: [String], used: inout Set<String>,
                          isDirectory: Bool,
                          renamed: inout [(original: String, chosen: String)]) -> URL {
        func resolve(_ parts: [String]) -> URL {
            parts.reduce(root) { $0.appendingPathComponent($1) }
        }
        func isTaken(_ parts: [String]) -> Bool {
            used.contains(PathSafety.collisionKey(parts))
                || FileManager.default.fileExists(atPath: resolve(parts).path)
        }
        let key = PathSafety.collisionKey(components)
        if !isTaken(components) {
            used.insert(key)
            return resolve(components)
        }
        var stem = components
        let lastName = stem.removeLast()
        let base = (lastName as NSString).deletingPathExtension
        let ext = (lastName as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            var probe = stem
            probe.append(candidate)
            if !isTaken(probe) {
                used.insert(PathSafety.collisionKey(probe))
                renamed.append((components.joined(separator: "/"),
                                probe.joined(separator: "/")))
                return resolve(probe)
            }
            index += 1
        }
    }

    /// Create every ancestor with a symlink check (defense in depth on
    /// top of O_EXCL creation; the openat hardening lands with the
    /// adversarial test pass).
    @discardableResult
    static func safeCreateDirectory(_ url: URL) throws -> [URL] {
        var current = url
        var stack: [URL] = []
        while !FileManager.default.fileExists(atPath: current.path) {
            stack.append(current)
            current = current.deletingLastPathComponent()
        }
        for dir in stack.reversed() {
            let parent = dir.deletingLastPathComponent()
            if let attrs = try? FileManager.default.attributesOfItem(atPath: parent.path),
               let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw Failure.safetyLimit("symlink in destination path")
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        }
        return stack.reversed()
    }
}

private extension Array where Element == URL {
    /// Record for cleanup: only files/directories created this run.
    mutating func appendingUniqueCreated(_ url: URL) throws {
        append(url)
    }
}

private extension Data {
    /// Stream blocks to a fresh file (O_EXCL: never overwrite).
    static func writeStreaming(to url: URL, _ body: ((Data) throws -> Void) throws -> Void) throws {
        let fd = url.path.withCString { cPath in
            open(cPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }
        guard fd >= 0 else {
            throw LibarchiveArchive.Failure.safetyLimit("cannot create \(url.lastPathComponent)")
        }
        defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try body { chunk in
                try handle.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
