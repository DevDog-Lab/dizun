import Foundation

/// Archive creation: walks the sources, filters macOS junk, NFC-normalizes
/// names, writes to an exclusive `.part` file and renames on completion, so a
/// half-written archive never appears under its real name.
public enum Packer {
    public struct Options: Sendable {
        public var nameEncoding: ZipWriter.NameEncoding = .utf8
        public var encryption: ZipWriter.Encryption = .none
        public var excludeMacJunk = true
        public init(nameEncoding: ZipWriter.NameEncoding = .utf8,
                    encryption: ZipWriter.Encryption = .none,
                    excludeMacJunk: Bool = true) {
            self.nameEncoding = nameEncoding
            self.encryption = encryption
            self.excludeMacJunk = excludeMacJunk
        }
    }

    public struct Result: Sendable {
        public var archiveURL: URL
        public var fileCount: Int
        public var directoryCount: Int
        /// Symlink sources skipped by policy (Windows round-trip safety).
        public var skippedSymlinks: [String]
        /// Junk entries (`.DS_Store` etc.) excluded by the filter.
        public var excludedJunk: [String]
    }

    /// Names macOS writes for its own bookkeeping; Windows Explorer shows
    /// them as garbage (SPEC §4). See `JunkFilter`.
    static let junkNames: Set<String> = JunkFilter.names

    static func isJunk(_ name: String) -> Bool {
        JunkFilter.isJunk(name)
    }

    /// Create a ZIP from files and/or folders. Each source contributes one
    /// top-level entry named after itself.
    public static func pack(_ sources: [URL], to destination: URL,
                            options: Options = Options(),
                            progress: ((String) -> Void)? = nil,
                            shouldCancel: (() -> Bool)? = nil) throws -> Result {
        guard !sources.isEmpty else {
            throw DizunError.ioFailure("no input files")
        }
        let partURL = destination.appendingPathExtension("part")
        guard !PathUtil.somethingExists(at: destination),
              !PathUtil.somethingExists(at: partURL) else {
            throw DizunError.ioFailure("destination already exists: \(destination.lastPathComponent)")
        }

        var files: [(name: String, url: URL)] = []
        var directories: [String] = []
        var skippedSymlinks: [String] = []
        var excludedJunk: [String] = []

        for source in sources {
            let rootName = FileNameEncoding.nfc(source.lastPathComponent)
            var isSymlink = false
            if let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey]) {
                isSymlink = values.isSymbolicLink ?? false
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
                throw DizunError.ioFailure("not found: \(source.lastPathComponent)")
            }
            if isSymlink {
                skippedSymlinks.append(rootName)
                continue
            }
            if isDir.boolValue {
                try collect(directory: source, prefix: rootName, partURL: partURL,
                            options: options,
                            files: &files, directories: &directories,
                            skippedSymlinks: &skippedSymlinks, excludedJunk: &excludedJunk)
                directories.append(rootName)
            } else {
                files.append((rootName, source))
            }
        }

        directories.sort()
        files.sort { $0.name < $1.name }

        var writerOptions = ZipWriter.Options()
        writerOptions.nameEncoding = options.nameEncoding
        writerOptions.encryption = options.encryption
        let writer = try ZipWriter(url: partURL, options: writerOptions)
        do {
            for dir in directories {
                progress?(dir)
                try writer.addDirectory(dir)
            }
            for file in files {
                if shouldCancel?() == true { throw DizunError.cancelled }
                progress?(file.name)
                try writer.addFile(file.name, fileURL: file.url)
            }
            try writer.finalize()
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }

        do {
            try FileManager.default.moveItem(at: partURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            throw DizunError.ioFailure("cannot finish \(destination.lastPathComponent)")
        }

        return Result(archiveURL: destination,
                      fileCount: files.count,
                      directoryCount: directories.count,
                      skippedSymlinks: skippedSymlinks,
                      excludedJunk: excludedJunk)
    }

    /// Recursive walk: real directories only (symlinked dirs are reported and
    /// skipped), junk filtered, and the in-progress `.part` archive excluded.
    private static func collect(directory: URL, prefix: String, partURL: URL,
                                options: Options,
                                files: inout [(name: String, url: URL)],
                                directories: inout [String],
                                skippedSymlinks: inout [String],
                                excludedJunk: inout [String]) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = FileNameEncoding.nfc(child.lastPathComponent)
            let path = prefix + "/" + name
            if child.path == partURL.path { continue }
            if options.excludeMacJunk && isJunk(name) {
                excludedJunk.append(path)
                continue
            }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink ?? false {
                skippedSymlinks.append(path)
                continue
            }
            if values.isDirectory ?? false {
                directories.append(path)
                try collect(directory: child, prefix: path, partURL: partURL,
                            options: options, files: &files, directories: &directories,
                            skippedSymlinks: &skippedSymlinks, excludedJunk: &excludedJunk)
            } else {
                files.append((path, child))
            }
        }
    }
}
