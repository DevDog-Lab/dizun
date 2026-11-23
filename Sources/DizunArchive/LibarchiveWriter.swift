import CArchive
import DizunCore
import Foundation

/// Creating non-ZIP archives (tar, tar.gz, tar.bz2, tar.xz, 7z) through
/// the vendored libarchive writer.
///
/// Conventions shared with the ZIP engine (`DizunCore.Packer`): macOS
/// junk (`__MACOSX/`, `.DS_Store`, `._*`) is excluded, output goes to a
/// `.part` file first and is renamed exclusively at the end so an
/// existing archive is never overwritten, and only regular files and
/// directories are stored (links/specials are skipped and reported).
public enum LibarchiveWriter {

    /// Shared counters threaded through the recursive walkers.
    public final class Stats {
        public var entryCount = 0
        public var totalBytes: UInt64 = 0
        public var skippedSpecial: [String] = []
        init() {}
    }

    public struct Outcome: Sendable {
        public var entryCount: Int
        public var totalBytes: UInt64
        public var skippedSpecial: [String]
        public var outputURL: URL
        init(entryCount: Int, totalBytes: UInt64, skippedSpecial: [String], outputURL: URL) {
            self.entryCount = entryCount
            self.totalBytes = totalBytes
            self.skippedSpecial = skippedSpecial
            self.outputURL = outputURL
        }
    }

    public enum Failure: Error, Equatable {
        case unsupportedFormat(String)
        case writer(String)
        case sourceVanished(String)
    }

    /// Create `output` from the given files/folders. The format decides
    /// container + filter; 7z uses libarchive's 7zip writer with its
    /// default (LZMA2) preset.
    public static func pack(_ sources: [URL], to output: URL,
                            format: ArchiveFormat) throws -> Outcome {
        dizun_archive_use_utf8_locale()
        guard format.canCreate else {
            throw Failure.unsupportedFormat(format.rawValue)
        }
        let partURL = URL(fileURLWithPath: output.path + ".part")
        try? FileManager.default.removeItem(at: partURL)

        guard let a = archive_write_new() else { throw Failure.writer("alloc") }
        defer { archive_write_free(a) }
        configure(a, format: format)
        let opened = partURL.path.withCString { archive_write_open_filename(a, $0) }
        guard opened == ARCHIVE_OK else {
            try? FileManager.default.removeItem(at: partURL)
            throw Failure.writer(String(cString: archive_error_string(a)))
        }

        let stats = Stats()
        do {
            for source in sources {
                let baseName = source.lastPathComponent
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
                    throw Failure.sourceVanished(source.lastPathComponent)
                }
                if isDir.boolValue {
                    try writeDirectory(a, url: source, archivePath: baseName, stats: stats)
                } else {
                    try writeFile(a, url: source, archivePath: baseName, stats: stats)
                }
            }
            guard archive_write_close(a) == ARCHIVE_OK else {
                throw Failure.writer(String(cString: archive_error_string(a)))
            }
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
        // Exclusive finalize: never overwrite an existing archive.
        do {
            try FileManager.default.moveItem(at: partURL, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw Failure.writer("destination exists: \(output.lastPathComponent)")
        }
        return Outcome(entryCount: stats.entryCount, totalBytes: stats.totalBytes,
                       skippedSpecial: stats.skippedSpecial, outputURL: output)
    }

    // MARK: - Configuration

    static func configure(_ a: OpaquePointer, format: ArchiveFormat) {
        switch format {
        case .tar, .tarGz, .tarBz2, .tarXz:
            archive_write_set_format_pax(a)
        case .sevenZ:
            archive_write_set_format_7zip(a)
        default:
            break
        }
        switch format {
        case .tarGz: archive_write_add_filter_gzip(a)
        case .tarBz2: archive_write_add_filter_bzip2(a)
        case .tarXz: archive_write_add_filter_xz(a)
        default: archive_write_add_filter_none(a)
        }
    }

    // MARK: - Tree walking

    /// Recursive directory listing in stable (localized-compare) order,
    /// excluding macOS junk the way the ZIP packer does.
    static func children(of directory: URL) -> [(url: URL, name: String)] {
        let items = (try? FileManager.default.contentsOfDirectory(
                        at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { !JunkFilter.isJunk($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { ($0, $0.lastPathComponent) }
    }

    static func writeDirectory(_ a: OpaquePointer, url: URL, archivePath: String,
                               stats: Stats) throws {
        try emitHeader(a, path: archivePath, isDirectory: true, size: 0, mtime: url)
        stats.entryCount += 1
        for child in children(of: url) {
            let childPath = archivePath + "/" + child.name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.url.path, isDirectory: &isDir) else {
                stats.skippedSpecial.append(childPath + " (vanished)")
                continue
            }
            if isDir.boolValue {
                try writeDirectory(a, url: child.url, archivePath: childPath, stats: stats)
            } else {
                try writeFile(a, url: child.url, archivePath: childPath, stats: stats)
            }
        }
    }

    static func writeFile(_ a: OpaquePointer, url: URL, archivePath: String,
                          stats: Stats) throws {
        // Symlinks and other specials are skipped, never followed.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let type = attrs[.type] as? FileAttributeType {
            if type == .typeSymbolicLink {
                stats.skippedSpecial.append(archivePath + " (symlink)")
                return
            }
            if type != .typeRegular {
                stats.skippedSpecial.append(archivePath + " (special)")
                return
            }
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try emitHeader(a, path: archivePath, isDirectory: false, size: UInt64(size), mtime: url)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.sourceVanished(archivePath)
        }
        defer { try? handle.close() }
        while true {
            let chunk = (try? handle.read(upToCount: 1 << 16)) ?? Data()
            if chunk.isEmpty { break }
            var written = 0
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if let base = raw.baseAddress {
                    written = archive_write_data(a, base, raw.count)
                }
            }
            guard written >= 0 else {
                throw Failure.writer(String(cString: archive_error_string(a)))
            }
            stats.totalBytes &+= UInt64(written)
        }
        try finishEntry(a)
        stats.entryCount += 1
    }

    static func emitHeader(_ a: OpaquePointer, path: String, isDirectory: Bool,
                           size: UInt64, mtime source: URL) throws {
        guard let entry = archive_entry_new() else {
            throw Failure.writer("entry alloc")
        }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, path)
        archive_entry_set_size(entry, isDirectory ? 0 : Int64(clamping: size))
        archive_entry_set_filetype(entry, isDirectory ? 0o040000 : 0o100000)
        archive_entry_set_perm(entry, isDirectory ? 0o755 : 0o644)
        if let mtime = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap({ $0.contentModificationDate })?.timeIntervalSince1970 {
            archive_entry_set_mtime(entry, Int(mtime), 0)
        }
        guard archive_write_header(a, entry) == ARCHIVE_OK else {
            throw Failure.writer(String(cString: archive_error_string(a)))
        }
        if isDirectory { try finishEntry(a) }
    }

    static func finishEntry(_ a: OpaquePointer) throws {
        let r = archive_write_finish_entry(a)
        guard r == ARCHIVE_OK || r == ARCHIVE_WARN else {
            throw Failure.writer(String(cString: archive_error_string(a)))
        }
    }
}
