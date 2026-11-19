import Foundation

/// Errors raised by the DIZUN ZIP engine.
public enum DizunError: Error, Equatable, Sendable {
    /// The file is not a ZIP (no end-of-central-directory record found).
    case notAZip
    /// Structural corruption: bad signatures, overlapping records, impossible sizes.
    case corrupt(String)
    /// Entry uses a compression method this build cannot read (only Store/Deflate).
    case unsupportedMethod(UInt16, entry: String)
    /// Entry is encrypted; crypto is deferred past the MVP (SPEC §8).
    case unsupportedEncryption(entry: String)
    /// An encrypted entry needs a password before anything is written.
    case passwordRequired
    /// The supplied password did not decrypt the entry.
    case wrongPassword(entry: String)
    /// Stored CRC-32 does not match the extracted bytes.
    case crcMismatch(entry: String)
    /// Actual byte count differs from the central directory's declaration.
    case sizeMismatch(entry: String)
    /// A safety limit refused the archive before or during extraction.
    case limitExceeded(String)
    /// Filesystem-level failure (open/create/write/rename).
    case ioFailure(String)
    /// A file name cannot be represented in the requested encoding. Never mangle silently.
    case nameNotEncodable(String)
    /// The name does not fit the format's 16-bit length field.
    case nameTooLong(String)
    /// The same entry name appears twice in one archive.
    case duplicateName(String)
    /// Cancellation was requested through the `shouldCancel` callback.
    case cancelled
}

extension DizunError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAZip: return "not a ZIP archive (end record not found)"
        case .corrupt(let why): return "corrupt archive: \(why)"
        case .unsupportedMethod(let m, let e): return "unsupported compression method \(m): \(e)"
        case .unsupportedEncryption(let e): return "encrypted entry not supported yet: \(e)"
        case .passwordRequired: return "password required"
        case .wrongPassword(let e): return "wrong password: \(e)"
        case .crcMismatch(let e): return "CRC-32 mismatch: \(e)"
        case .sizeMismatch(let e): return "size does not match the directory: \(e)"
        case .limitExceeded(let why): return "safety limit exceeded: \(why)"
        case .ioFailure(let why): return "I/O failure: \(why)"
        case .nameNotEncodable(let n): return "name not representable in the target encoding: \(n)"
        case .nameTooLong(let n): return "name too long for the ZIP format: \(n)"
        case .duplicateName(let n): return "duplicate entry name: \(n)"
        case .cancelled: return "cancelled"
        }
    }
}
