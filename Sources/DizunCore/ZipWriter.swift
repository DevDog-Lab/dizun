import Foundation

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

    public struct Options: Sendable {
        public var nameEncoding: NameEncoding = .utf8
        public init() {}
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
        eocd += Zip.littleEndian16(0)               // comment length
        try write(Data(eocd))
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
        let flags: UInt16 = encoded.flagUTF8 ? Zip.flagUTF8 : 0

        // Compress in-memory payloads first so the header carries real values;
        // streaming payloads patch CRC/compressed-size back afterwards.
        var crc: UInt32 = 0
        var compressedSize: UInt64 = 0
        var method: UInt16 = Zip.methodStore
        var body: Data = Data()
        switch payload {
        case .data(let data):
            crc = CRC32.checksum(data)
            compressedSize = UInt64(data.count)
            if !isDirectory, data.count > 0 {
                let deflated = try DeflateStream.compress(data)
                if deflated.count < data.count {
                    method = Zip.methodDeflate
                    body = deflated
                    compressedSize = UInt64(deflated.count)
                } else {
                    body = data
                }
            } else {
                body = data
            }
        case .stream:
            method = Zip.methodDeflate
        }

        // Local file header: 30 fixed bytes, then the name, then the extra
        // field (ZIP64 sizes) — in that on-disk order.
        var header: [UInt8] = []
        header += Zip.littleEndian32(Zip.localFileHeaderSignature)
        header += Zip.littleEndian16(useZip64 ? 45 : 20)
        header += Zip.littleEndian16(flags)
        header += Zip.littleEndian16(method)
        header += Zip.littleEndian16(dosTime)
        header += Zip.littleEndian16(dosDate)
        if case .stream = payload {
            header += [0, 0, 0, 0]                  // CRC-32, patched after the stream
            header += [0, 0, 0, 0]                  // compressed size, patched
        } else {
            header += Zip.littleEndian32(crc)
            header += Zip.littleEndian32(UInt32(truncatingIfNeeded: compressedSize))
        }
        header += Zip.littleEndian32(useZip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: uncompressedSize))
        header += Zip.littleEndian16(UInt16(encoded.bytes.count))
        header += Zip.littleEndian16(useZip64 ? 20 : 0)
        try write(Data(header))
        try write(encoded.bytes)

        // ZIP64 extra: id + size + uncompressed(8) + compressed(8, patched
        // when streaming).
        var zip64CompressedPatch: UInt64? = nil
        if useZip64 {
            let slotOffset = localOffset + 30 + UInt64(encoded.bytes.count) + 4 + 8
            zip64CompressedPatch = slotOffset
            var extra: [UInt8] = [0x01, 0x00]
            extra += Zip.littleEndian16(16)
            extra += Zip.littleEndian64(uncompressedSize)
            extra += [0, 0, 0, 0, 0, 0, 0, 0]
            try write(Data(extra))
        }

        switch payload {
        case .data:
            try write(body)
        case .stream(let url, let onBytes):
            let streamed = try writeStreamed(url: url,
                                             localOffset: localOffset,
                                             zip64CompressedPatch: zip64CompressedPatch,
                                             onBytes: onBytes)
            crc = streamed.crc
            compressedSize = streamed.size
        }

        records.append(CentralRecord(nameBytes: encoded.bytes,
                                     flags: flags,
                                     method: method,
                                     dosTime: dosTime,
                                     dosDate: dosDate,
                                     crc32: crc,
                                     compressedSize: compressedSize,
                                     uncompressedSize: uncompressedSize,
                                     localHeaderOffset: localOffset,
                                     externalAttributes: externalAttributes(isDirectory: isDirectory,
                                                                            posixMode: posixMode),
                                     versionNeeded: useZip64 ? 45 : 20))
    }

    /// Deflate a file straight into the archive, then patch CRC-32 and
    /// compressed size back into the local header (no data descriptor).
    private func writeStreamed(url: URL, localOffset: UInt64,
                               zip64CompressedPatch: UInt64?,
                               onBytes: ((UInt64) -> Void)?) throws -> (crc: UInt32, size: UInt64) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var runningCRC: UInt32 = CRC32.initial
        var total: UInt64 = 0
        try DeflateStream.run(encode: true, read: {
            let chunk = try input.read(upToCount: 256 << 10) ?? Data()
            if chunk.isEmpty { return nil }
            // CRC is over the *source* bytes; the write callback below sees
            // the deflated stream, not the file content.
            CRC32.update(&runningCRC, chunk)
            return chunk
        }, write: { chunk in
            try self.write(chunk)
            total += UInt64(chunk.count)
            onBytes?(total)
        })
        let finalizedCRC = CRC32.finalize(runningCRC)

        handle.seek(toFileOffset: localOffset + 14)
        try handle.write(contentsOf: Data(Zip.littleEndian32(finalizedCRC)))
        if let patch = zip64CompressedPatch {
            handle.seek(toFileOffset: patch)
            try handle.write(contentsOf: Data(Zip.littleEndian64(total)))
        } else {
            handle.seek(toFileOffset: localOffset + 18)
            try handle.write(contentsOf: Data(Zip.littleEndian32(UInt32(truncatingIfNeeded: total))))
        }
        handle.seek(toFileOffset: position)
        return (finalizedCRC, total)
    }

    private func externalAttributes(isDirectory: Bool, posixMode: UInt16) -> UInt32 {
        let dosAttrs: UInt32 = isDirectory ? 0x10 : 0
        return UInt32(posixMode) << 16 | dosAttrs
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
        var extraLength: UInt16 = 0
        if needsZip64Extra {
            extraLength = 4 + (uncompSentinel ? 8 : 0) + (sizeSentinel ? 8 : 0) + (offsetSentinel ? 8 : 0)
        }
        header += Zip.littleEndian16(extraLength)
        header += Zip.littleEndian16(0)            // comment length
        header += Zip.littleEndian16(0)            // disk start
        header += Zip.littleEndian16(0)            // internal attributes
        header += Zip.littleEndian32(record.externalAttributes)
        header += Zip.littleEndian32(offsetSentinel ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: record.localHeaderOffset))
        try write(Data(header))
        try write(record.nameBytes)
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
