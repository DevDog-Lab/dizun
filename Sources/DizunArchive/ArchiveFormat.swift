import Foundation

/// Archive families DIZUN can open or create. ZIP goes through the
/// first-party DizunCore engine; everything else through the vendored
/// libarchive adapter. The cases describe capabilities honestly —
/// `rar`/`rar5`/`lzh` are extract-only, and nothing here claims support
/// for encrypted or split volumes.
public enum ArchiveFormat: String, Sendable, Equatable, CaseIterable {
    case zip
    case tar
    case tarGz
    case tarBz2
    case tarXz
    case sevenZ
    case rar
    case rar5
    case lzh
    /// Bare compressed streams (`.gz`, `.bz2`, `.xz`): single payload,
    /// possibly a tar inside.
    case gzipStream
    case bzip2Stream
    case xzStream

    /// True when this format can be *created* by DIZUN.
    public var canCreate: Bool {
        switch self {
        case .zip, .tar, .tarGz, .tarBz2, .tarXz, .sevenZ: true
        case .rar, .rar5, .lzh, .gzipStream, .bzip2Stream, .xzStream: false
        }
    }

    /// User-facing label (ja only for now; the UI layer localizes).
    public var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .tar: "TAR"
        case .tarGz: "TAR.GZ"
        case .tarBz2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        case .sevenZ: "7z"
        case .rar: "RAR"
        case .rar5: "RAR5"
        case .lzh: "LZH"
        case .gzipStream: "GZIP"
        case .bzip2Stream: "BZIP2"
        case .xzStream: "XZ"
        }
    }

    /// File extensions (lowercased, compound suffixes kept whole) this
    /// format is commonly delivered as. Naming only — detection below is
    /// content-based.
    public var commonExtensions: [String] {
        switch self {
        case .zip: ["zip"]
        case .tar: ["tar"]
        case .tarGz: ["tar.gz", "tgz"]
        case .tarBz2: ["tar.bz2", "tbz", "tbz2"]
        case .tarXz: ["tar.xz", "txz"]
        case .sevenZ: ["7z"]
        case .rar: ["rar"]
        case .rar5: ["rar"]
        case .lzh: ["lzh", "lha"]
        case .gzipStream: ["gz"]
        case .bzip2Stream: ["bz2"]
        case .xzStream: ["xz"]
        }
    }
}

/// Content-sniffing detection. The extension only seeds a hint; the
/// magic bytes decide. Streams that can wrap a tar (`.gz`/`.bz2`/`.xz`)
/// are decompressed for a bounded prefix to see whether a tar follows.
public enum FormatDetector {
    /// Minimum bytes worth reading before giving up on detection.
    public static let probeSize = 1024

    public static func detect(url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: probeSize) else { return nil }
        defer { try? handle.close() }
        return detect(headBytes: [UInt8](head))
    }

    /// `headBytes` should cover at least the magic region of every
    /// candidate format (tar's `ustar` sits at offset 257, so ~512 bytes).
    public static func detect(headBytes: [UInt8]) -> ArchiveFormat? {
        func has(_ magic: [UInt8], at offset: Int = 0) -> Bool {
            guard headBytes.count >= offset + magic.count else { return false }
            return Array(headBytes[offset..<(offset + magic.count)]) == magic
        }
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06])
            || has([0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if has([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZ }
        if has([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) { return .rar }
        if has([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]) { return .rar5 }
        if has([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xzStream }
        if has([0x42, 0x5A, 0x68]) { return .bzip2Stream }
        if has([0x1F, 0x8B]) { return .gzipStream }
        if has(Array("ustar".utf8), at: 257) { return .tar }
        if looksLikeLHA(headBytes) { return .lzh }
        if looksLikeTarChecksum(headBytes) { return .tar }
        return nil
    }

    /// LHA level-1 header: size byte, method "-lh?-", … (levels 2/3 start
    /// with a size byte of 0x00/0x20 followed by their own layout).
    static func looksLikeLHA(_ b: [UInt8]) -> Bool {
        guard b.count >= 5 else { return false }
        let method = String(decoding: b[1..<5], as: UTF8.self)
        return b[0] > 0 && method.hasPrefix("-lh")
    }

    /// Old (pre-ustar) tar: verify the octal checksum field.
    static func looksLikeTarChecksum(_ b: [UInt8]) -> Bool {
        guard b.count >= 512 else { return false }
        let storedField = String(decoding: b[148..<156], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let stored = UInt64(storedField, radix: 8) else { return false }
        var sum: UInt64 = 0
        for i in 0..<148 { sum += UInt64(b[i]) }
        for i in 156..<512 { sum += UInt64(b[i]) }  // checksum field counts as spaces
        // Some writers store the sum with a trailing NUL/space pair; accept
        // both the plain sum and the unsigned sum + 256 convention.
        return sum == stored || sum + 256 == stored
    }
}
