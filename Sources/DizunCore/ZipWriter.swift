import Foundation
import Security

/// Streaming ZIP writer.
///
/// Entry data is deflated straight to the output file and CRC/compressed-size
/// are patched back afterwards, so no data descriptors are emitted — the
/// layout old tools (and Windows Explorer) read most reliably. Files up to
/// `inMemoryCompressLimit` are compressed in memory and fall back to Store
/// when deflate does not shrink them; larger files always stream deflate.
public final class ZipWriter {
    public enum NameEncoding: Sendable, Equatable {
        /// NFC UTF-8 with the UTF-8 flag (bit 11) on non-ASCII names.
        case utf8
        /// CP932 for legacy Japanese Windows tools; unmappable names error.
        case cp932
    }

    /// Entry encryption (SPEC §4). File entries only; names stay readable.
    public enum Encryption: Sendable, Equatable {
        case none
        /// WinZip AE-2, AES-256 — the modern default.
        case aes256(password: String)
        /// PKWARE traditional — weak (known-plaintext attacks); legacy
        /// compatibility only. Callers must warn when producing it.
        case zipCrypto(password: String)
    }

    public struct Options: Sendable {
        public var nameEncoding: NameEncoding = .utf8
        public var encryption: Encryption = .none
        public init(nameEncoding: NameEncoding = .utf8, encryption: Encryption = .none) {
            self.nameEncoding = nameEncoding
            self.encryption = encryption
        }
    }

    /// Files larger than this switch from Store-if-better to streaming
    /// deflate (they are worth compressing and rarely fit memory twice).
    public static let inMemoryCompressLimit: UInt64 = 16 << 20
    /// Entries at least this large get ZIP64 records (the headroom below
    /// 4 GiB absorbs deflate's worst-case expansion).
    var zip64Threshold: UInt64 = 0xFFFF_0000

    private struct CentralRecord {
        var nameBytes: Data
        var flags: UInt16
        var method: UInt16
        var dosTime: UInt16
        var dosDate: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var externalAttributes: UInt32
        var versionNeeded: UInt16
        var aesActualMethod: UInt16?
    }

    private enum Payload {
        case data(Data)
        case stream(URL, ((UInt64) -> Void)?)
    }

    private let handle: FileHandle
    private let options: Options
    private var records: [CentralRecord] = []
    private var seenNames = Set<String>()
    private var position: UInt64 = 0
    private var finalized = false

    /// `url` must not exist: creation is exclusive, so a file that appears
    /// between the caller's name choice and this call fails instead of being
    /// truncated. `Packer` writes to a `.part` path and renames afterwards.
    public init(url: URL, options: Options = Options()) throws {
        do {
            handle = try PathUtil.createFileExclusively(at: url).handle
        } catch {
            throw DizunError.ioFailure("cannot create \(url.lastPathComponent)")
        }
        self.options = options
    }

    /// Archive-level comment stored in the end record. DIZUN uses it to mark
    /// nested (double-ZIP) archives so extraction can auto-unwrap them.
    public var archiveComment: String?

    deinit { try? handle.close() }

    // MARK: - Public API

    /// Add a directory entry (the name gets a trailing slash).
    public func addDirectory(_ name: String, modificationDate: Date = Date(),
                             posixMode: UInt16 = 0o755) throws {
        let dirName = name.hasSuffix("/") ? name : name + "/"
        try addEntry(name: dirName, isDirectory: true, modificationDate: modificationDate,
                     uncompressedSize: 0, posixMode: posixMode, payload: .data(Data()))
    }

    /// Add a file from memory (compressed in memory, Store when deflate does
    /// not shrink it).
    public func addFile(_ name: String, data: Data, modificationDate: Date = Date(),
                        posixMode: UInt16 = 0o644) throws {
        try addEntry(name: name, isDirectory: false, modificationDate: modificationDate,
                     uncompressedSize: UInt64(data.count), posixMode: posixMode, payload: .data(data))
    }

    /// Add a file from disk. Files over `inMemoryCompressLimit` stream
    /// straight to the archive with patch-back; `onBytes` reports compressed
    /// bytes written for progress.
    public func addFile(_ name: String, fileURL: URL,
                        modificationDate: Date? = nil,
                        posixMode: UInt16? = nil,
                        onBytes: ((UInt64) -> Void)? = nil) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = modificationDate ?? (attrs[.modificationDate] as? Date) ?? Date()
        let mode = posixMode ?? ((attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644)
        if size <= Self.inMemoryCompressLimit {
            let data = size == 0 ? Data() : try Data(contentsOf: fileURL, options: .mappedIfSafe)
            try addEntry(name: name, isDirectory: false, modificationDate: mtime,
                         uncompressedSize: size, posixMode: mode, payload: .data(data))
            onBytes?(size)
        } else {
            try addEntry(name: name, isDirectory: false, modificationDate: mtime,
                         uncompressedSize: size, posixMode: mode,
                         payload: .stream(fileURL, onBytes))
        }
    }

    /// Write the central directory and end records; closes the file.
    public func finalize() throws {
        guard !finalized else { return }
        finalized = true
        defer { try? handle.close() }

        let directoryOffset = position
        for record in records {
            try writeCentralRecord(record)
        }
        let directorySize = position - directoryOffset

        let needsZip64 = records.count > 0xFFFE
            || directoryOffset + directorySize > 0xFFFF_FFFF
            || records.contains { record in
                record.uncompressedSize > 0xFFFF_FFFF
                    || record.compressedSize > 0xFFFF_FFFF
                    || record.localHeaderOffset > 0xFFFF_FFFF
            }

        if needsZip64 {
            try writeZip64EndRecord(directoryOffset: directoryOffset, directorySize: directorySize)
        }

        var eocd: [UInt8] = []
        eocd += Zip.littleEndian32(Zip.endRecordSignature)
        eocd += Zip.littleEndian16(0)               // this disk
        eocd += Zip.littleEndian16(0)               // disk with the directory
        eocd += Zip.littleEndian16(needsZip64 ? 0xFFFF : UInt16(truncatingIfNeeded: records.count))
        eocd += Zip.littleEndian16(needsZip64 ? 0xFFFF : UInt16(truncatingIfNeeded: records.count))
        eocd += Zip.littleEndian32(needsZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: directorySize))
        eocd += Zip.littleEndian32(needsZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: directoryOffset))
        let comment = Data((archiveComment ?? "").utf8)
        eocd += Zip.littleEndian16(UInt16(comment.count))
        try write(Data(eocd))
        try write(comment)
    }

    // MARK: - Entry writing

    private func addEntry(name: String, isDirectory: Bool, modificationDate: Date,
                          uncompressedSize: UInt64, posixMode: UInt16,
                          payload: Payload) throws {
        guard !finalized else {
            throw DizunError.ioFailure("archive already finalized")
        }
        let trimmed = isDirectory && name.hasSuffix("/") ? String(name.dropLast()) : name
        let nfcName = FileNameEncoding.nfc(trimmed)
        guard seenNames.insert(nfcName).inserted else {
            throw DizunError.duplicateName(nfcName)
        }
        // Directory entries are stored with a trailing slash — without it,
        // readers cannot tell a directory from an empty file.
        let encoded = try encodeName(isDirectory ? nfcName + "/" : nfcName)
        guard encoded.bytes.count <= 0xFFFF else {
            throw DizunError.nameTooLong(nfcName)
        }

        let (dosDate, dosTime) = DosDateTime.pack(modificationDate)
        let useZip64 = uncompressedSize > zip64Threshold
        let localOffset = position
        let encryption = isDirectory ? Encryption.none : options.encryption
        var flags: UInt16 = encoded.flagUTF8 ? Zip.flagUTF8 : 0
        if case .none = encryption {} else { flags |= Zip.flagEncrypted }

        var crc: UInt32 = 0
        var compressedSize: UInt64 = 0
        var baseMethod: UInt16 = Zip.methodStore
        var body: Data = Data()
        switch payload {
        case .data(let data):
            crc = CRC32.checksum(data)
            compressedSize = UInt64(data.count)
            if !isDirectory, data.count > 0 {
                let deflated = try DeflateStream.compress(data)
                if deflated.count < data.count {
                    baseMethod = Zip.methodDeflate
                    body = deflated
                    compressedSize = UInt64(deflated.count)
                } else {
                    body = data
                }
            } else {
                body = data
            }
        case .stream:
            baseMethod = Zip.methodDeflate
        }

        // Encryption framing. Method becomes 99 (AES wrapper) with the real
        // method in the 0x9901 extra; ZipCrypto keeps the plain method with
        // a 12-byte header prepended to the data.
        var aesExtra: Data? = nil
        var storedMethod = baseMethod
        var crcField: UInt32 = crc
        var bodyStorage: Data = body          // in-memory path: what hits the file
        var zipCryptoCipher: ZipCryptoCipher? = nil
        var aesCipher: WinZipAES? = nil
        switch encryption {
        case .none:
            break
        case .aes256(let password):
            aesExtra = Self.aesExtraField(actualMethod: baseMethod)
            storedMethod = Zip.methodAES
            crcField = 0                       // AE-2 authenticates via HMAC
            let salt = try Self.randomData(16)
            var cipher = WinZipAES(encryptWith: password, strength: .aes256, salt: salt)
            var out = Data()
            out.append(salt)
            out.append(cipher.derivedVerifier)
            if case .stream = payload {
                aesCipher = cipher
            } else {
                out.append(cipher.process(body))
                out.append(cipher.authCode())
            }
            bodyStorage = out
            compressedSize = UInt64(out.count)
        case .zipCrypto(let password):
            // The check byte is the high CRC byte (no data descriptors
            // here). Streaming needs a CRC pre-pass over the source.
            if case .stream(let url, _) = payload {
                crc = try Self.crcOfContents(at: url)
            }
            crcField = crc
            let random = try Self.randomData(ZipCryptoCipher.headerSize - 1)
            var out = Data()
            var cipher = ZipCryptoCipher(password: password, randomBytes: random,
                                         checkByte: UInt8(crc >> 24), header: &out)
            if case .stream = payload {
                zipCryptoCipher = cipher
            } else {
                out.append(cipher.encrypt(body))
            }
            bodyStorage = out
            compressedSize = UInt64(out.count)
        }

        let versionNeeded: UInt16 = useZip64 ? 45 : (aesExtra != nil ? 51 : 20)

        // Local file header: 30 fixed bytes, then the name, then the extra
        // fields (AES descriptor, then ZIP64 sizes).
        let headerCRC: UInt32
        let headerCompressed: UInt32
        if case .stream = payload {
            headerCRC = crcField               // real for ZipCrypto, 0 for AES/plain
            headerCompressed = 0                // patched after the stream
        } else {
            headerCRC = crcField
            headerCompressed = UInt32(truncatingIfNeeded: compressedSize)
        }
        var header: [UInt8] = []
        header += Zip.littleEndian32(Zip.localFileHeaderSignature)
        header += Zip.littleEndian16(versionNeeded)
        header += Zip.littleEndian16(flags)
        header += Zip.littleEndian16(storedMethod)
        header += Zip.littleEndian16(dosTime)
        header += Zip.littleEndian16(dosDate)
        header += Zip.littleEndian32(headerCRC)
        header += Zip.littleEndian32(headerCompressed)
        header += Zip.littleEndian32(useZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: uncompressedSize))
        header += Zip.littleEndian16(UInt16(encoded.bytes.count))
        let extraLength = UInt16((aesExtra?.count ?? 0) + (useZip64 ? 20 : 0))
        header += Zip.littleEndian16(extraLength)
        try write(Data(header))
        try write(encoded.bytes)
        if let aesExtra {
            try write(aesExtra)
        }

        // ZIP64 extra: id + size + uncompressed(8) + compressed(8, patched
        // when streaming).
        var zip64CompressedPatch: UInt64? = nil
        if useZip64 {
            let slotOffset = localOffset + 30 + UInt64(encoded.bytes.count)
                + UInt64(aesExtra?.count ?? 0) + 4 + 8
            zip64CompressedPatch = slotOffset
            var extra: [UInt8] = [0x01, 0x00]
            extra += Zip.littleEndian16(16)
            extra += Zip.littleEndian64(uncompressedSize)
            extra += [0, 0, 0, 0, 0, 0, 0, 0]
            try write(Data(extra))
        }

        switch payload {
        case .data:
            try write(bodyStorage)
            if case .zipCrypto = encryption {
                // In-memory ZipCrypto appended the encrypted body to the
                // header already; sizes accounted above.
            }
        case .stream(let url, let onBytes):
            let streamed = try writeStreamed(url: url,
                                             localOffset: localOffset,
                                             zip64CompressedPatch: zip64CompressedPatch,
                                             zipCrypto: zipCryptoCipher,
                                             aes: aesCipher,
                                             precomputedCRC: crcField,
                                             onBytes: onBytes)
            crc = streamed.crc
            compressedSize = streamed.size
            if case .none = encryption {
                crcField = streamed.crc
            }
        }

        records.append(CentralRecord(nameBytes: encoded.bytes,
                                     flags: flags,
                                     method: storedMethod,
                                     dosTime: dosTime,
                                     dosDate: dosDate,
                                     crc32: crcField,
                                     compressedSize: compressedSize,
                                     uncompressedSize: uncompressedSize,
                                     localHeaderOffset: localOffset,
                                     externalAttributes: externalAttributes(isDirectory: isDirectory,
                                                                            posixMode: posixMode),
                                     versionNeeded: versionNeeded,
                                     aesActualMethod: aesExtra != nil ? baseMethod : nil))
    }

    /// Deflate a file straight into the archive, then patch CRC-32 and
    /// compressed size back into the local header (no data descriptor).
    private func writeStreamed(url: URL, localOffset: UInt64,
                               zip64CompressedPatch: UInt64?,
                               zipCrypto: ZipCryptoCipher?,
                               aes: WinZipAES?,
                               precomputedCRC: UInt32,
                               onBytes: ((UInt64) -> Void)?) throws -> (crc: UInt32, size: UInt64) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var runningCRC: UInt32 = CRC32.initial
        var total: UInt64 = 0
        var zipCryptoCipher = zipCrypto
        var aesCipher = aes
        try DeflateStream.run(encode: true, read: {
            let chunk = try input.read(upToCount: 256 << 10) ?? Data()
            if chunk.isEmpty { return nil }
            // CRC is over the *source* bytes; the write callback below sees
            // the deflated (and possibly encrypted) stream, not the content.
            CRC32.update(&runningCRC, chunk)
            return chunk
        }, write: { deflated in
            var out = deflated
            if var cipher = zipCryptoCipher {
                out = cipher.encrypt(deflated)
                zipCryptoCipher = cipher
            }
            if var cipher = aesCipher {
                out = cipher.process(deflated)
                aesCipher = cipher
            }
            try self.write(out)
            total += UInt64(out.count)
            onBytes?(total)
        })
        var finalTotal = total
        if var cipher = aesCipher {
            let code = cipher.authCode()
            try write(code)
            finalTotal += UInt64(code.count)
        }

        // ZipCrypto's CRC was precomputed (its check byte needed it); AES
        // stores 0. Plain streaming patches the freshly computed one.
        let patchedCRC: UInt32 = (zipCrypto != nil || aes != nil)
            ? precomputedCRC : CRC32.finalize(runningCRC)

        handle.seek(toFileOffset: localOffset + 14)
        try handle.write(contentsOf: Data(Zip.littleEndian32(patchedCRC)))
        if let patch = zip64CompressedPatch {
            handle.seek(toFileOffset: patch)
            try handle.write(contentsOf: Data(Zip.littleEndian64(finalTotal)))
        } else {
            handle.seek(toFileOffset: localOffset + 18)
            try handle.write(contentsOf: Data(Zip.littleEndian32(UInt32(truncatingIfNeeded: finalTotal))))
        }
        handle.seek(toFileOffset: position)
        return (patchedCRC, finalTotal)
    }

    private func externalAttributes(isDirectory: Bool, posixMode: UInt16) -> UInt32 {
        let dosAttrs: UInt32 = isDirectory ? 0x10 : 0
        return UInt32(posixMode) << 16 | dosAttrs
    }

    /// The 0x9901 extra field: AE version 2, vendor "AE", strength 3
    /// (AES-256), and the real compression method underneath the wrapper.
    private static func aesExtraField(actualMethod: UInt16) -> Data {
        var extra: [UInt8] = [0x01, 0x99]
        extra += Zip.littleEndian16(7)
        extra += Zip.littleEndian16(2)             // AE-2
        extra += [0x41, 0x45]                      // "AE"
        extra += [3]                               // strength: AES-256
        extra += Zip.littleEndian16(actualMethod)
        return Data(extra)
    }

    private static func randomData(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw DizunError.ioFailure("system random unavailable")
        }
        return Data(bytes)
    }

    /// ZipCrypto's check byte needs the plaintext CRC before any data is
    /// written, so streaming sources get a pre-pass.
    private static func crcOfContents(at url: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc: UInt32 = CRC32.initial
        while true {
            let chunk = try input.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            CRC32.update(&crc, chunk)
        }
        return CRC32.finalize(crc)
    }

    private func writeCentralRecord(_ record: CentralRecord) throws {
        let sizeSentinel = record.compressedSize > 0xFFFF_FFFF
        let uncompSentinel = record.uncompressedSize > 0xFFFF_FFFF
        let offsetSentinel = record.localHeaderOffset > 0xFFFF_FFFF
        let needsZip64Extra = sizeSentinel || uncompSentinel || offsetSentinel

        var header: [UInt8] = []
        header += Zip.littleEndian32(Zip.centralDirectorySignature)
        header += Zip.littleEndian16((3 << 8) | record.versionNeeded)  // made by Unix
        header += Zip.littleEndian16(record.versionNeeded)
        header += Zip.littleEndian16(record.flags)
        header += Zip.littleEndian16(record.method)
        header += Zip.littleEndian16(record.dosTime)
        header += Zip.littleEndian16(record.dosDate)
        header += Zip.littleEndian32(record.crc32)
        header += Zip.littleEndian32(sizeSentinel ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: record.compressedSize))
        header += Zip.littleEndian32(uncompSentinel ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: record.uncompressedSize))
        header += Zip.littleEndian16(UInt16(record.nameBytes.count))
        let aesBytes: Data? = record.aesActualMethod.map { Self.aesExtraField(actualMethod: $0) }
        var extraLength: UInt16 = UInt16(aesBytes?.count ?? 0)
        if needsZip64Extra {
            extraLength += 4 + (uncompSentinel ? 8 : 0) + (sizeSentinel ? 8 : 0) + (offsetSentinel ? 8 : 0)
        }
        header += Zip.littleEndian16(extraLength)
        header += Zip.littleEndian16(0)            // comment length
        header += Zip.littleEndian16(0)            // disk start
        header += Zip.littleEndian16(0)            // internal attributes
        header += Zip.littleEndian32(record.externalAttributes)
        header += Zip.littleEndian32(offsetSentinel ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: record.localHeaderOffset))
        try write(Data(header))
        try write(record.nameBytes)
        if let aesBytes {
            try write(aesBytes)
        }
        if needsZip64Extra {
            var extra: [UInt8] = [0x01, 0x00]
            var dataSize: UInt16 = 0
            if uncompSentinel { dataSize += 8 }
            if sizeSentinel { dataSize += 8 }
            if offsetSentinel { dataSize += 8 }
            extra += Zip.littleEndian16(dataSize)
            if uncompSentinel { extra += Zip.littleEndian64(record.uncompressedSize) }
            if sizeSentinel { extra += Zip.littleEndian64(record.compressedSize) }
            if offsetSentinel { extra += Zip.littleEndian64(record.localHeaderOffset) }
            try write(Data(extra))
        }
    }

    private func writeZip64EndRecord(directoryOffset: UInt64, directorySize: UInt64) throws {
        let zip64Offset = position
        var record: [UInt8] = []
        record += Zip.littleEndian32(Zip.zip64EndRecordSignature)
        record += Zip.littleEndian64(44)            // size of the rest of this record
        record += Zip.littleEndian16((3 << 8) | 45) // made by Unix
        record += Zip.littleEndian16(45)            // version needed
        record += Zip.littleEndian32(0)             // this disk
        record += Zip.littleEndian32(0)             // disk with the directory
        record += Zip.littleEndian64(UInt64(records.count))
        record += Zip.littleEndian64(UInt64(records.count))
        record += Zip.littleEndian64(directorySize)
        record += Zip.littleEndian64(directoryOffset)
        try write(Data(record))                     // 56 bytes total
        var locator: [UInt8] = []
        locator += Zip.littleEndian32(Zip.zip64LocatorSignature)
        locator += Zip.littleEndian32(0)            // disk with the ZIP64 EOCD
        locator += Zip.littleEndian64(zip64Offset)
        locator += Zip.littleEndian32(1)            // total disks
        try write(Data(locator))
    }

    private func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        position += UInt64(data.count)
    }

    private struct EncodedName {
        var bytes: Data
        var flagUTF8: Bool
    }

    private func encodeName(_ nfcName: String) throws -> EncodedName {
        let hasNonASCII = nfcName.unicodeScalars.contains(where: { !$0.isASCII })
        switch options.nameEncoding {
        case .utf8:
            guard let bytes = nfcName.data(using: .utf8) else {
                throw DizunError.nameNotEncodable(nfcName)
            }
            return EncodedName(bytes: bytes, flagUTF8: hasNonASCII)
        case .cp932:
            // Unmappable characters (e.g. emoji) stop the write with an error —
            // never a silent replacement (SPEC §4).
            guard let bytes = nfcName.data(using: FileNameEncoding.cp932) else {
                throw DizunError.nameNotEncodable(nfcName)
            }
            return EncodedName(bytes: bytes, flagUTF8: false)
        }
    }
}
