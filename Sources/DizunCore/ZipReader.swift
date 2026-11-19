import Foundation

/// Central-directory ZIP reader with safety validation.
///
/// The whole archive is held in memory for the MVP (bounded by
/// `ExtractionLimits.maxArchiveBytes`; a streaming reader is future work).
/// Before any byte is extracted, the local header is cross-checked against
/// the central directory — signature, name bytes and stream bounds — which is
/// what defeats overlapping-record attacks.
public final class ZipReader {
    /// Undecoded central-directory record.
    private struct RawEntry {
        var nameBytes: Data
        var utf8NameOverride: String?   // Info-ZIP Unicode-Path extra (0x7075)
        var flags: UInt16
        var method: UInt16
        var dosTime: UInt16
        var dosDate: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var externalAttributes: UInt32
        var madeByUnix: Bool
        var aesStrength: UInt8?
        var aesActualMethod: UInt16?
    }

    public private(set) var entries: [ZipEntry] = []
    public let detectedEncoding: NameEncoding
    public let archiveSize: UInt64

    private let data: Data
    private let rawEntries: [RawEntry]
    private let limits: ExtractionLimits

    public convenience init(url: URL, limits: ExtractionLimits = ExtractionLimits()) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw DizunError.ioFailure("cannot read \(url.lastPathComponent)")
        }
        try self.init(data: data, limits: limits)
    }

    public init(data: Data, limits: ExtractionLimits = ExtractionLimits()) throws {
        self.data = data
        self.limits = limits
        self.archiveSize = UInt64(data.count)

        guard UInt64(data.count) <= limits.maxArchiveBytes else {
            throw DizunError.limitExceeded(
                "archive exceeds the current in-memory reader cap (\(limits.maxArchiveBytes) bytes)")
        }
        let raw = try ZipReader.parseCentralDirectory(data, limits: limits)
        self.rawEntries = raw

        // Archive-wide encoding for entries without the UTF-8 flag.
        let undecided = raw.filter { entry in
            entry.utf8NameOverride == nil && (entry.flags & Zip.flagUTF8) == 0
        }
        self.detectedEncoding = FileNameEncoding.detect(undecided.map(\.nameBytes))
        self.entries = raw.map { rawEntry in
            ZipReader.decode(rawEntry, encoding: detectedEncoding)
        }
    }

    /// The entry list re-decoded with a manually chosen encoding (preview /
    /// manual switch in the UI-to-be; SPEC §5).
    public func entriesDecoded(as encoding: NameEncoding) -> [ZipEntry] {
        rawEntries.map { ZipReader.decode($0, encoding: encoding) }
    }

    /// Total declared uncompressed size — the pre-flight budget figure.
    public var declaredTotalSize: UInt64 {
        rawEntries.reduce(0) { $0 + $1.uncompressedSize }
    }

    /// Extract one entry, streaming chunks to `write`. Verifies the local
    /// header, decrypts encrypted entries with `password` (nil on an
    /// encrypted entry throws `passwordRequired`), enforces the declared
    /// size, the expansion ratio and — except for AE-2 entries, which
    /// authenticate with HMAC instead — the CRC-32.
    public func extract(_ entry: ZipEntry, password: String? = nil,
                        write: (Data) throws -> Void) throws {
        guard let raw = rawEntries.first(where: { $0.localHeaderOffset == entry.localHeaderOffset
            && $0.nameBytes == entry.nameBytes }) else {
            throw DizunError.corrupt("entry not found in this archive")
        }
        guard UInt64(entry.uncompressedSize) <= limits.maxEntrySize else {
            throw DizunError.limitExceeded("entry \(entry.name): declared size over the per-entry cap")
        }

        let encrypted = raw.flags & Zip.flagEncrypted != 0
        if encrypted, password == nil {
            throw DizunError.passwordRequired
        }

        // Method dispatch: plain entries are Store/Deflate; encrypted ones
        // are method 99 (WinZip AES wrapping Store/Deflate) or plain
        // Store/Deflate under ZipCrypto.
        var effectiveMethod = raw.method
        if !encrypted {
            guard effectiveMethod == Zip.methodStore || effectiveMethod == Zip.methodDeflate else {
                throw DizunError.unsupportedMethod(effectiveMethod, entry: entry.name)
            }
        } else if raw.method == Zip.methodAES {
            guard raw.aesActualMethod == Zip.methodStore || raw.aesActualMethod == Zip.methodDeflate,
                  raw.aesStrength != nil else {
                throw DizunError.corrupt("AES entry without a usable 0x9901 extra field")
            }
            effectiveMethod = raw.aesActualMethod!
        } else if raw.method != Zip.methodStore && raw.method != Zip.methodDeflate {
            throw DizunError.unsupportedMethod(raw.method, entry: entry.name)
        }

        // Cross-check the local header before trusting the data location.
        let dataStart = try ZipReader.validateLocalHeader(of: raw, in: data)
        let dataEnd = dataStart + Int(raw.compressedSize)
        guard dataEnd <= data.count else {
            throw DizunError.corrupt("entry \(entry.name): data runs past the end of the archive")
        }
        let payload = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataEnd))

        // Decrypt first; the codec then runs over the plaintext bytes.
        let compressed: Data
        let authenticatesByHMAC: Bool
        if encrypted, raw.method == Zip.methodAES {
            let strength = WinZipAES.Strength(rawValue: raw.aesStrength!)!
            let saltBytes = strength.saltBytes
            let overhead = UInt64(saltBytes + 2 + WinZipAES.authCodeSize)
            guard raw.compressedSize >= overhead else {
                throw DizunError.corrupt("entry \(entry.name): AES data shorter than its framing")
            }
            let salt = payload.prefix(saltBytes)
            let verifier = payload.subdata(in: (payload.startIndex + saltBytes)..<(payload.startIndex + saltBytes + 2))
            let cipherEnd = payload.startIndex + Int(raw.compressedSize) - WinZipAES.authCodeSize
            let cipher = payload.subdata(in: (payload.startIndex + saltBytes + 2)..<cipherEnd)
            let trailer = payload.suffix(WinZipAES.authCodeSize)
            guard var aes = WinZipAES(password: password!, strength: strength,
                                      salt: salt, passwordVerifier: verifier) else {
                throw DizunError.wrongPassword(entry: entry.name)
            }
            var decrypted = aes.process(cipher)
            guard aes.verifyAuthCode(trailer) else {
                decrypted = Data()
                throw DizunError.wrongPassword(entry: entry.name)
            }
            compressed = decrypted
            authenticatesByHMAC = true
        } else if encrypted {
            guard raw.compressedSize >= ZipCryptoCipher.headerSize else {
                throw DizunError.corrupt("entry \(entry.name): encrypted data shorter than its header")
            }
            // Check byte: high CRC byte, or high DOS-time byte when the
            // entry carries a data descriptor (streamed by the producer).
            let checkByte: UInt8
            if raw.flags & Zip.flagHasDataDescriptor != 0, raw.crc32 == 0 {
                checkByte = UInt8(raw.dosTime >> 8)
            } else {
                checkByte = UInt8(raw.crc32 >> 24)
            }
            let header = payload.prefix(ZipCryptoCipher.headerSize)
            let body = payload.subdata(in: (payload.startIndex + ZipCryptoCipher.headerSize)..<payload.endIndex)
            guard var cipher = ZipCryptoCipher(password: password!, header: header,
                                               checkByte: checkByte) else {
                throw DizunError.wrongPassword(entry: entry.name)
            }
            compressed = cipher.decrypt(body)
            authenticatesByHMAC = false
        } else {
            compressed = payload
            authenticatesByHMAC = false
        }

        if effectiveMethod == Zip.methodDeflate, compressed.count > 0 {
            let ratio = Double(raw.uncompressedSize) / Double(compressed.count)
            guard ratio <= limits.maxExpansionRatio else {
                throw DizunError.limitExceeded(
                    "entry \(entry.name): expansion ratio \(Int(ratio))x over the cap")
            }
        }

        var crc: UInt32 = CRC32.initial
        var written: UInt64 = 0
        func emit(_ chunk: Data) throws {
            guard written + UInt64(chunk.count) <= raw.uncompressedSize else {
                throw DizunError.sizeMismatch(entry: entry.name)
            }
            CRC32.update(&crc, chunk)
            try write(chunk)
            written += UInt64(chunk.count)
        }

        if effectiveMethod == Zip.methodStore {
            try emit(compressed)
        } else {
            var fed = false
            try DeflateStream.run(encode: false, read: {
                if fed { return nil }
                fed = true
                return compressed.isEmpty ? nil : compressed
            }, write: { try emit($0) })
        }
        guard written == raw.uncompressedSize else {
            throw DizunError.sizeMismatch(entry: entry.name)
        }
        // AE-2 stores CRC 0 and authenticates via HMAC (verified above);
        // AE-1 archives that kept the CRC still get it checked.
        if !authenticatesByHMAC || raw.crc32 != 0 {
            guard CRC32.finalize(crc) == raw.crc32 else {
                throw DizunError.crcMismatch(entry: entry.name)
            }
        }
    }

    // MARK: - Parsing

    private static func decode(_ raw: RawEntry, encoding: NameEncoding) -> ZipEntry {
        let flagged = (raw.flags & Zip.flagUTF8) != 0 || raw.utf8NameOverride != nil
        let name: String
        if let override = raw.utf8NameOverride {
            name = override
        } else if (raw.flags & Zip.flagUTF8) != 0 {
            name = FileNameEncoding.decode(raw.nameBytes, as: .utf8)
        } else {
            name = FileNameEncoding.decode(raw.nameBytes, as: encoding)
        }
        let unixMode: UInt16? = raw.madeByUnix ? UInt16((raw.externalAttributes >> 16) & 0xFFFF) : nil
        let isDirectory = name.hasSuffix("/") || (unixMode.map { $0 & 0xF000 == 0x4000 } ?? false)
        let isSymlink = unixMode.map { $0 & 0xF000 == 0xA000 } ?? false
        return ZipEntry(nameBytes: raw.nameBytes,
                        name: name,
                        isUTF8Flagged: flagged,
                        isEncrypted: raw.flags & Zip.flagEncrypted != 0,
                        method: raw.method,
                        isDirectory: isDirectory,
                        isSymlink: isSymlink,
                        crc32: raw.crc32,
                        compressedSize: raw.compressedSize,
                        uncompressedSize: raw.uncompressedSize,
                        localHeaderOffset: raw.localHeaderOffset,
                        dosDate: raw.dosDate,
                        dosTime: raw.dosTime,
                        unixMode: unixMode,
                        aesStrength: raw.aesStrength,
                        aesActualMethod: raw.aesActualMethod)
    }

    private static func parseCentralDirectory(_ data: Data, limits: ExtractionLimits) throws -> [RawEntry] {
        guard data.count >= 22 else { throw DizunError.notAZip }
        let eocd = try findEndRecord(in: data)

        var cursor = Data.Cursor(data, at: eocd)
        _ = try cursor.u32()                       // signature (already matched)
        _ = try cursor.u16()                       // disk number
        _ = try cursor.u16()                       // central-directory disk
        _ = try cursor.u16()                       // entries on this disk
        var totalEntries = Int(try cursor.u16())
        var directorySize = UInt64(try cursor.u32())
        var directoryOffset = UInt64(try cursor.u32())
        let commentLength = Int(try cursor.u16())
        guard cursor.offset + commentLength == data.count else {
            throw DizunError.corrupt("trailing bytes after the ZIP comment")
        }

        // ZIP64: the classic record stores 0xFFFF/0xFFFFFFFF sentinels and the
        // real values live in the ZIP64 end record.
        if eocd >= 20 {
            var locator = Data.Cursor(data, at: eocd - 20)
            if try locator.u32() == Zip.zip64LocatorSignature {
                _ = try locator.u32()              // disk with the ZIP64 EOCD
                let zip64Offset = try locator.u64()
                _ = try locator.u32()              // total disks
                guard Int(zip64Offset) + 56 <= data.count else {
                    throw DizunError.corrupt("ZIP64 end record out of bounds")
                }
                var z = Data.Cursor(data, at: Int(zip64Offset))
                guard try z.u32() == Zip.zip64EndRecordSignature else {
                    throw DizunError.corrupt("ZIP64 locator points at a non-ZIP64 record")
                }
                _ = try z.u64()                    // size of ZIP64 EOCD
                _ = try z.u16(); _ = try z.u16()   // version made by / needed
                _ = try z.u32(); _ = try z.u32()   // disk numbers
                _ = try z.u64()                    // entries on this disk
                totalEntries = Int(try z.u64())    // total entries
                directorySize = try z.u64()
                directoryOffset = try z.u64()
            }
        }

        guard totalEntries >= 0, totalEntries <= limits.maxEntries else {
            throw DizunError.limitExceeded("entry count \(totalEntries) over the cap")
        }
        guard directoryOffset + directorySize <= UInt64(data.count) else {
            throw DizunError.corrupt("central directory runs past the end of the archive")
        }

        var entries: [RawEntry] = []
        entries.reserveCapacity(totalEntries)
        var offset = Int(directoryOffset)
        for _ in 0..<totalEntries {
            var c = Data.Cursor(data, at: offset)
            guard try c.u32() == Zip.centralDirectorySignature else {
                throw DizunError.corrupt("bad central-directory record at \(offset)")
            }
            let versionMadeBy = try c.u16()
            _ = try c.u16()                        // version needed
            let flags = try c.u16()
            let method = try c.u16()
            let dosTime = try c.u16()
            let dosDate = try c.u16()
            let crc = try c.u32()
            var compressedSize = UInt64(try c.u32())
            var uncompressedSize = UInt64(try c.u32())
            let nameLength = Int(try c.u16())
            let extraLength = Int(try c.u16())
            let commentLength = Int(try c.u16())
            _ = try c.u16()                        // disk start
            _ = try c.u16()                        // internal attributes
            let externalAttributes = try c.u32()
            var localOffset = UInt64(try c.u32())
            let nameBytes = try c.bytes(nameLength)
            let extra = try c.bytes(extraLength)
            _ = try c.bytes(commentLength)

            var utf8NameOverride: String?
            var aesStrength: UInt8?
            var aesActualMethod: UInt16?
            (uncompressedSize, compressedSize, localOffset, utf8NameOverride, aesStrength, aesActualMethod) =
                try applyExtra(extra,
                               uncompressed: uncompressedSize,
                               compressed: compressedSize,
                               localOffset: localOffset,
                               nameBytes: nameBytes,
                               method: method)

            entries.append(RawEntry(nameBytes: nameBytes,
                                    utf8NameOverride: utf8NameOverride,
                                    flags: flags,
                                    method: method,
                                    dosTime: dosTime,
                                    dosDate: dosDate,
                                    crc32: crc,
                                    compressedSize: compressedSize,
                                    uncompressedSize: uncompressedSize,
                                    localHeaderOffset: localOffset,
                                    externalAttributes: externalAttributes,
                                    madeByUnix: versionMadeBy >> 8 == 3,
                                    aesStrength: aesStrength,
                                    aesActualMethod: aesActualMethod))
            offset = c.offset
        }
        return entries
    }

    /// Walk the extra fields: ZIP64 sizes/offset (0x0001), the Info-ZIP
    /// Unicode Path (0x7075, trusted only when its CRC matches the raw name)
    /// and the WinZip AES descriptor (0x9901).
    private static func applyExtra(_ extra: Data,
                                   uncompressed: UInt64, compressed: UInt64,
                                   localOffset: UInt64, nameBytes: Data,
                                   method: UInt16)
        throws -> (UInt64, UInt64, UInt64, String?, UInt8?, UInt16?) {
        var uncompressedSize = uncompressed
        var compressedSize = compressed
        var localHeaderOffset = localOffset
        var utf8NameOverride: String?
        var aesStrength: UInt8?
        var aesActualMethod: UInt16?
        var cursor = Data.Cursor(extra)
        while cursor.remaining >= 4 {
            let headerID = try cursor.u16()
            let size = Int(try cursor.u16())
            let body = try cursor.bytes(size)
            var b = Data.Cursor(body)
            switch headerID {
            case 0x0001:
                if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try b.u64() }
                if compressedSize == 0xFFFF_FFFF { compressedSize = try b.u64() }
                if localHeaderOffset == 0xFFFF_FFFF { localHeaderOffset = try b.u64() }
            case 0x7075:
                _ = try b.u8()                     // version
                let nameCRC = try b.u32()
                let utf8 = b.data.subdata(in: (b.data.startIndex + b.offset)..<b.data.endIndex)
                if CRC32.checksum(nameBytes) == nameCRC,
                   let decoded = String(data: utf8, encoding: .utf8) {
                    utf8NameOverride = decoded
                }
            case 0x9901:
                // version(2) vendor "AE"(2) strength(1) actual method(2)
                guard method == Zip.methodAES, size >= 7 else { break }
                _ = try b.u16()                    // vendor version (1=AE-1, 2=AE-2)
                _ = try b.u16()                    // vendor ID "AE"
                aesStrength = try b.u8()
                aesActualMethod = try b.u16()
            default:
                break
            }
        }
        return (uncompressedSize, compressedSize, localHeaderOffset, utf8NameOverride,
                aesStrength, aesActualMethod)
    }

    /// Scan backwards for the end-of-central-directory record; the comment
    /// length must account for every byte after it.
    private static func findEndRecord(in data: Data) throws -> Int {
        let maxComment = 65_535 + 22
        let floor = max(0, data.count - maxComment)
        var p = data.count - 22
        while p >= floor {
            if data[data.startIndex + p] == 0x50,
               data[data.startIndex + p + 1] == 0x4b,
               data[data.startIndex + p + 2] == 0x05,
               data[data.startIndex + p + 3] == 0x06 {
                var c = Data.Cursor(data, at: p)
                _ = try c.u32()
                try c.skip(16)
                let commentLength = Int(try c.u16())
                if p + 22 + commentLength == data.count { return p }
            }
            p -= 1
        }
        throw DizunError.notAZip
    }

    /// Verify the local header matches the central record and return the
    /// absolute offset where the entry's compressed data starts.
    private static func validateLocalHeader(of raw: RawEntry, in data: Data) throws -> Int {
        let offset = Int(raw.localHeaderOffset)
        guard offset + 30 <= data.count else {
            throw DizunError.corrupt("local header out of bounds")
        }
        var c = Data.Cursor(data, at: offset)
        guard try c.u32() == Zip.localFileHeaderSignature else {
            throw DizunError.corrupt("local header signature mismatch")
        }
        try c.skip(22)                             // version…uncompressed size
        let nameLength = Int(try c.u16())
        let extraLength = Int(try c.u16())
        let localName = try c.bytes(nameLength)
        // Same bytes in both records — an overlap/name-forgery attack breaks here.
        guard localName == raw.nameBytes else {
            throw DizunError.corrupt("local header name differs from the central directory")
        }
        let dataStart = offset + 30 + nameLength + extraLength
        guard dataStart <= data.count else {
            throw DizunError.corrupt("local header runs past the end of the archive")
        }
        return dataStart
    }
}
