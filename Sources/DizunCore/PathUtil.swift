import Darwin
import Foundation

/// Filesystem helpers: exclusive creates and unique names. Everything here
/// exists so DIZUN never overwrites an existing file (SPEC §6).
enum PathUtil {
    struct ExclusiveFile {
        let handle: FileHandle
        let url: URL
        func close() { try? handle.close() }
    }

    /// O_CREAT|O_EXCL create. Fails with `File exists` if anything is already
    /// there — this is the guard that makes "never overwrite" real even
    /// against a race with another process.
    static func createFileExclusively(at url: URL) throws -> ExclusiveFile {
        let fd = url.path.withCString { cPath -> Int32 in
            open(cPath, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666))
        }
        guard fd >= 0 else {
            throw DizunError.ioFailure("create \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return ExclusiveFile(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), url: url)
    }

    /// Exclusive mkdir; same guarantee for directories.
    static func createDirectoryExclusively(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    static func somethingExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// First of `name`, "name 2", "name 3", … for which `taken` is false.
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        if !taken(name) { return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// Ledger of paths this operation created; failure removes exactly these
    /// and nothing else (the "clean up only what it created" rule).
    struct OwnedItems {
        private var items: [URL] = []
        mutating func adopt(_ url: URL) { items.append(url) }
        mutating func removeAll() {
            for url in items.reversed() {
                try? FileManager.default.removeItem(at: url)
            }
            items.removeAll()
        }
    }
}
