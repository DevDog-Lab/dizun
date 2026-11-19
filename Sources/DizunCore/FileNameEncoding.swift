import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Encoding used for entry names that lack the UTF-8 flag (bit 11).
public enum NameEncoding: String, Sendable, Equatable {
    case utf8
    case cp932
}

/// File-name encoding transforms for Windows round-trips.
///
/// macOS file APIs return decomposed UTF-8 (NFD), which Windows renders with
/// split dakuten ("テ゛ータ"); every name DIZUN stores is NFC-normalized first.
/// CP932 (Windows-31J) is what Japanese Windows tools assume when the entry
/// lacks the UTF-8 flag. The detect-then-decode order below (UTF-8 validation
/// first, CP932 second) follows the audited zip-porter design (MIT,
/// SHA 9868489): CP932 bytes are almost never valid UTF-8, while UTF-8
/// Japanese bytes usually *do* decode as CP932 — as mojibake.
public enum FileNameEncoding {
    /// CP932 = Shift_JIS with the Microsoft extension characters (①, ㈱, the
    /// Windows ～). `String.Encoding.shiftJIS` alone rejects those, so the CF
    /// DOS-Japanese encoding is required.
    public static let cp932: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    /// NFC-normalize a file name.
    public static func nfc(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Decide the archive-wide encoding for entries without the UTF-8 flag.
    public static func detect(_ rawNames: [Data]) -> NameEncoding {
        let nonASCII = rawNames.filter { name in name.contains { $0 >= 0x80 } }
        guard !nonASCII.isEmpty else { return .utf8 }
        if nonASCII.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) {
            return .utf8
        }
        return .cp932
    }

    /// Decode raw name bytes, falling back across encodings rather than
    /// failing: an archive with undecodable names must still be listable.
    /// Latin-1 maps every byte — garbled but lossless; the percent form is the
    /// last resort so the result is never nil.
    public static func decode(_ raw: Data, as encoding: NameEncoding) -> String {
        switch encoding {
        case .utf8:
            if let s = String(data: raw, encoding: .utf8) { return s }
            if let s = String(data: raw, encoding: cp932) { return s }
        case .cp932:
            if let s = String(data: raw, encoding: cp932) { return s }
            if let s = String(data: raw, encoding: .utf8) { return s }
        }
        return String(data: raw, encoding: .isoLatin1)
            ?? raw.map { String(format: "%%%02X", $0) }.joined()
    }

    /// Encode for an entry header. Nil when the name contains characters the
    /// encoding cannot represent — the caller surfaces that as an error and
    /// never silently mangles (SPEC §4).
    public static func encode(_ name: String, as encoding: NameEncoding) -> Data? {
        switch encoding {
        case .utf8: return nfc(name).data(using: .utf8)
        case .cp932: return nfc(name).data(using: cp932)
        }
    }
}
