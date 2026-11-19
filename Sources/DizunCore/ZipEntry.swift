import Foundation

/// One entry as read from the central directory. `nameBytes` keeps the
/// undecoded bytes so diagnostics and re-encoding can reference the source of
/// truth (SPEC §5: keep raw bytes as diagnostic information).
public struct ZipEntry: Sendable, Equatable {
    public let nameBytes: Data
    /// Name decoded with the archive-wide (or forced) encoding.
    public let name: String
    /// True when the entry carried the UTF-8 flag (bit 11).
    public let isUTF8Flagged: Bool
    /// True when the entry declares encryption (flag bit 0) — refused at
    /// extraction in the MVP but visible in listings/previews.
    public let isEncrypted: Bool
    public let method: UInt16
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let localHeaderOffset: UInt64
    public let dosDate: UInt16
    public let dosTime: UInt16
    /// Unix permission/mode bits from external attributes, when present.
    public let unixMode: UInt16?
}

extension ZipEntry {
    public var modificationDate: Date? {
        DosDateTime.unpack(date: dosDate, time: dosTime)
    }
}

/// Byte-level ZIP constants, little-endian encoders and the cursor reader.
public enum Zip {
    public static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    public static let centralDirectorySignature: UInt32 = 0x0201_4b50
    public static let endRecordSignature: UInt32 = 0x0605_4b50
    public static let zip64EndRecordSignature: UInt32 = 0x0606_4b50
    public static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    public static let flagEncrypted: UInt16 = 0x0001
    public static let flagHasDataDescriptor: UInt16 = 0x0008
    public static let flagUTF8: UInt16 = 0x0800
    public static let methodStore: UInt16 = 0
    public static let methodDeflate: UInt16 = 8

    public static func littleEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    public static func littleEndian32(_ value: UInt32) -> [UInt8] {
        littleEndian16(UInt16(value & 0xFFFF)) + littleEndian16(UInt16(value >> 16))
    }

    public static func littleEndian64(_ value: UInt64) -> [UInt8] {
        littleEndian32(UInt32(value & 0xFFFF_FFFF)) + littleEndian32(UInt32(value >> 32))
    }
}

extension Data {
    struct Cursor {
        let data: Data
        var offset: Int
        init(_ data: Data, at offset: Int = 0) { self.data = data; self.offset = offset }
        var remaining: Int { data.count - offset }
        mutating func u8() throws -> UInt8 {
            guard remaining >= 1 else { throw DizunError.corrupt("unexpected end of data") }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }
        mutating func u16() throws -> UInt16 {
            let lo = UInt16(try u8()), hi = UInt16(try u8())
            return lo | hi << 8
        }
        mutating func u32() throws -> UInt32 {
            let lo = UInt32(try u16()), hi = UInt32(try u16())
            return lo | hi << 16
        }
        mutating func u64() throws -> UInt64 {
            let lo = UInt64(try u32()), hi = UInt64(try u32())
            return lo | hi << 32
        }
        mutating func bytes(_ count: Int) throws -> Data {
            guard remaining >= count else { throw DizunError.corrupt("unexpected end of data") }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }
        mutating func skip(_ count: Int) throws {
            guard remaining >= count else { throw DizunError.corrupt("unexpected end of data") }
            offset += count
        }
    }
}

/// Safety limits for extraction (SPEC §6: bound archive expansion and
/// resource usage). Every field is enforced, not advisory.
public struct ExtractionLimits: Sendable {
    /// Maximum number of entries in one archive.
    public var maxEntries: Int = 10_000
    /// Maximum declared total uncompressed size across the archive.
    public var maxTotalUncompressed: UInt64 = 8 << 30
    /// Maximum declared size of a single entry.
    public var maxEntrySize: UInt64 = 4 << 30
    /// Maximum compressed→uncompressed ratio per deflated entry.
    public var maxExpansionRatio: Double = 200
    /// Headroom left free on the destination volume by the pre-flight check.
    public var spaceMargin: UInt64 = 64 << 20
    /// The MVP reader holds the archive in memory; larger files are refused
    /// (documented limitation until the streaming reader lands).
    public var maxArchiveBytes: UInt64 = 2 << 30
    public init() {}
}
