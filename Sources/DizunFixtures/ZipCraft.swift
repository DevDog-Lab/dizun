import CryptoKit
import DizunCore
import Foundation

/// Byte-level ZIP builder for tests. Independent of `ZipWriter` on purpose:
/// the reader must be validated against arbitrarily crafted containers —
/// hostile overlaps, forged sizes, legacy encodings — not only archives the
/// writer happens to produce.
public enum ZipCraft {
    public struct EntrySpec {
        public var name: Data
        public var utf8Flag: Bool
        public var method: UInt16
        public var payload: Data            // stored bytes as they appear in the file
        public var declaredUncompressed: UInt32
        public var declaredCompressed: UInt32?
        public var declaredCRC: UInt32?
        public var unixMode: UInt16?
        public var localNameOverride: Data?

        public init(name: String, utf8Flag: Bool = true, method: UInt16 = 0,
                    payload: Data = Data(), declaredUncompressed: UInt32? = nil,
                    declaredCompressed: UInt32? = nil, declaredCRC: UInt32? = nil,
                    unixMode: UInt16? = nil, localNameOverride: Data? = nil) {
            self.name = Data(name.utf8)
            self.utf8Flag = utf8Flag
            self.method = method
            self.payload = payload
            self.declaredUncompressed = declaredUncompressed ?? UInt32(payload.count)
            self.declaredCompressed = declaredCompressed
            self.declaredCRC = declaredCRC
            self.unixMode = unixMode
            self.localNameOverride = localNameOverride
        }

        public init(nameBytes: Data, utf8Flag: Bool, method: UInt16 = 0,
                    payload: Data = Data(), declaredUncompressed: UInt32? = nil,
                    declaredCompressed: UInt32? = nil, declaredCRC: UInt32? = nil,
                    unixMode: UInt16? = nil) {
            self.name = nameBytes
            self.utf8Flag = utf8Flag
            self.method = method
            self.payload = payload
            self.declaredUncompressed = declaredUncompressed ?? UInt32(payload.count)
            self.declaredCompressed = declaredCompressed
            self.declaredCRC = declaredCRC
            self.unixMode = unixMode
            self.localNameOverride = nil
        }
    }

    /// Assemble a well-formed ZIP except where a spec intentionally lies.
    public static func archive(_ entries: [EntrySpec]) -> Data {
        var out = Data()
        var central: [(offset: UInt32, spec: EntrySpec, crc: UInt32, comp: UInt32)] = []

        for spec in entries {
            let localOffset = UInt32(out.count)
            let crc = spec.declaredCRC ?? DizunCRC32.checksum(spec.payload)
            let compressed = spec.declaredCompressed ?? UInt32(spec.payload.count)
            let localName = spec.localNameOverride ?? spec.name
            let flags: UInt16 = spec.utf8Flag ? Zip.flagUTF8 : 0

            var header: [UInt8] = []
            header += Zip.littleEndian32(Zip.localFileHeaderSignature)
            header += Zip.littleEndian16(20)
            header += Zip.littleEndian16(flags)
            header += Zip.littleEndian16(spec.method)
            header += Zip.littleEndian16(0)          // time
            header += Zip.littleEndian16(0x21)       // date: 1980-01-01
            header += Zip.littleEndian32(crc)
            header += Zip.littleEndian32(compressed)
            header += Zip.littleEndian32(spec.declaredUncompressed)
            header += Zip.littleEndian16(UInt16(localName.count))
            header += Zip.littleEndian16(0)          // extra length
            out += Data(header)
            out += localName
            out += spec.payload
            central.append((localOffset, spec, crc, compressed))
        }

        let directoryOffset = UInt32(out.count)
        for record in central {
            let external: UInt32 = record.spec.unixMode.map { UInt32($0) << 16 } ?? 0
            var header: [UInt8] = []
            header += Zip.littleEndian32(Zip.centralDirectorySignature)
            header += Zip.littleEndian16((3 << 8) | 20)  // made by Unix
            header += Zip.littleEndian16(20)
            header += Zip.littleEndian16(record.spec.utf8Flag ? Zip.flagUTF8 : 0)
            header += Zip.littleEndian16(record.spec.method)
            header += Zip.littleEndian16(0)
            header += Zip.littleEndian16(0x21)
            header += Zip.littleEndian32(record.crc)
            header += Zip.littleEndian32(record.comp)
            header += Zip.littleEndian32(record.spec.declaredUncompressed)
            header += Zip.littleEndian16(UInt16(record.spec.name.count))
            header += Zip.littleEndian16(0)          // extra length
            header += Zip.littleEndian16(0)          // comment length
            header += Zip.littleEndian16(0)          // disk start
            header += Zip.littleEndian16(0)
            header += Zip.littleEndian32(external)
            header += Zip.littleEndian32(record.offset)
            out += Data(header)
            out += record.spec.name
        }
        let directorySize = UInt32(out.count) - directoryOffset

        var eocd: [UInt8] = []
        eocd += Zip.littleEndian32(Zip.endRecordSignature)
        eocd += Zip.littleEndian16(0)
        eocd += Zip.littleEndian16(0)
        eocd += Zip.littleEndian16(UInt16(entries.count))
        eocd += Zip.littleEndian16(UInt16(entries.count))
        eocd += Zip.littleEndian32(directorySize)
        eocd += Zip.littleEndian32(directoryOffset)
        eocd += Zip.littleEndian16(0)
        out += Data(eocd)
        return out
    }

    /// Valid raw-deflate payload for fixture entries.
    public static func deflate(_ data: Data) -> Data {
        (try? DizunDeflate.compress(data)) ?? Data()
    }

    /// A ZIP64 variant: central sizes/offset use 0xFFFFFFFF sentinels with the
    /// real values in the 0x0001 extra, and the archive ends with the ZIP64
    /// end record + locator before the classic EOCD.
    public static func archiveZip64(_ entries: [EntrySpec]) -> Data {
        var out = Data()
        var central: [(offset: UInt32, spec: EntrySpec, crc: UInt32, comp: UInt32)] = []
        for spec in entries {
            let localOffset = UInt32(out.count)
            let crc = spec.declaredCRC ?? DizunCRC32.checksum(spec.payload)
            let compressed = spec.declaredCompressed ?? UInt32(spec.payload.count)
            var header: [UInt8] = []
            header += Zip.littleEndian32(Zip.localFileHeaderSignature)
            header += Zip.littleEndian16(45)             // version needed: 4.5
            header += Zip.littleEndian16(spec.utf8Flag ? Zip.flagUTF8 : 0)
            header += Zip.littleEndian16(spec.method)
            header += Zip.littleEndian16(0)
            header += Zip.littleEndian16(0x21)
            header += Zip.littleEndian32(crc)
            header += Zip.littleEndian32(compressed)
            header += Zip.littleEndian32(UInt32(clamping: spec.declaredUncompressed))
            header += Zip.littleEndian16(UInt16(spec.name.count))
            header += Zip.littleEndian16(0)
            out += Data(header)
            out += spec.name
            out += spec.payload
            central.append((localOffset, spec, crc, compressed))
        }

        let directoryOffset = UInt32(out.count)
        for record in central {
            let external: UInt32 = record.spec.unixMode.map { UInt32($0) << 16 } ?? 0
            var header: [UInt8] = []
            header += Zip.littleEndian32(Zip.centralDirectorySignature)
            header += Zip.littleEndian16((3 << 8) | 45)
            header += Zip.littleEndian16(45)
            header += Zip.littleEndian16(record.spec.utf8Flag ? Zip.flagUTF8 : 0)
            header += Zip.littleEndian16(record.spec.method)
            header += Zip.littleEndian16(0)
            header += Zip.littleEndian16(0x21)
            header += Zip.littleEndian32(record.crc)
            header += Zip.littleEndian32(0xFFFF_FFFF)    // compressed sentinel
            header += Zip.littleEndian32(0xFFFF_FFFF)    // uncompressed sentinel
            header += Zip.littleEndian16(UInt16(record.spec.name.count))
            header += Zip.littleEndian16(4 + 8 + 8 + 8)  // ZIP64 extra: sizes + offset
            header += Zip.littleEndian16(0)
            header += Zip.littleEndian16(0)
            header += Zip.littleEndian16(0)
            header += Zip.littleEndian32(external)
            header += Zip.littleEndian32(0xFFFF_FFFF)    // local offset sentinel
            out += Data(header)
            out += record.spec.name
            var extra: [UInt8] = [0x01, 0x00]
            extra += Zip.littleEndian16(24)
            extra += Zip.littleEndian64(UInt64(record.spec.declaredUncompressed))
            extra += Zip.littleEndian64(UInt64(record.comp))
            extra += Zip.littleEndian64(UInt64(record.offset))
            out += Data(extra)
        }
        let directorySize = UInt32(out.count) - directoryOffset

        // ZIP64 end record (56) + locator (20).
        let zip64Offset = UInt32(out.count)
        var z: [UInt8] = []
        z += Zip.littleEndian32(Zip.zip64EndRecordSignature)
        z += Zip.littleEndian64(44)
        z += Zip.littleEndian16((3 << 8) | 45)
        z += Zip.littleEndian16(45)
        z += Zip.littleEndian32(0)
        z += Zip.littleEndian32(0)
        z += Zip.littleEndian64(UInt64(entries.count))
        z += Zip.littleEndian64(UInt64(entries.count))
        z += Zip.littleEndian64(UInt64(directorySize))
        z += Zip.littleEndian64(UInt64(directoryOffset))
        out += Data(z)
        var loc: [UInt8] = []
        loc += Zip.littleEndian32(Zip.zip64LocatorSignature)
        loc += Zip.littleEndian32(0)
        loc += Zip.littleEndian64(UInt64(zip64Offset))
        loc += Zip.littleEndian32(1)
        out += Data(loc)

        var eocd: [UInt8] = []
        eocd += Zip.littleEndian32(Zip.endRecordSignature)
        eocd += Zip.littleEndian16(0)
        eocd += Zip.littleEndian16(0)
        eocd += Zip.littleEndian16(0xFFFF)
        eocd += Zip.littleEndian16(0xFFFF)
        eocd += Zip.littleEndian32(0xFFFF_FFFF)
        eocd += Zip.littleEndian32(0xFFFF_FFFF)
        eocd += Zip.littleEndian16(0)
        out += Data(eocd)
        return out
    }
}
