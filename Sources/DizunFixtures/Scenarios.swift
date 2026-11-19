import CryptoKit
import DizunCore
import Foundation

/// Gate-B verification scenarios (SPEC §13). Every scenario throws on failure;
/// they run unchanged from the XCTest suite and from `dizun selftest`, so the
/// engine is verifiable even where XCTest is unavailable.
public enum Scenarios {
    public struct ScenarioFailure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    static func assert(_ condition: Bool, _ message: String) throws {
        if !condition { throw ScenarioFailure(message: message) }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dizun-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func makeFile(_ name: String, data: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Deterministic pseudo-random payload (reproducible failures).
    static func pseudoRandom(_ count: Int, seed: UInt64 = 0x44495A554E) -> Data {
        var state = seed
        var data = Data(capacity: count)
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    static func contents(_ path: String, in dir: URL) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(path))
    }

    // MARK: - Scenarios

    /// Round-trip with Japanese names, nesting, empty file, deflate payload;
    /// names must come back NFC and byte-identical (SHA-256).
    public static func roundTripJapanese() throws {
        let work = tempDir("roundtrip")
        defer { try? FileManager.default.removeItem(at: work) }
        let src = work.appendingPathComponent("入力", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        // Explicit NFD ("テ" + combining voiced mark) — what macOS file APIs hand back.
        let nfdName = "テ\u{3099}ータ.txt"
        let cases: [(String, Data)] = [
            ("readme.txt", Data("DIZUN round trip\n".utf8)),
            ("資料/報告書.txt", Data("日本語の内容。壊れないこと。".utf8)),
            ("資料/ひらがな・カタカナ.txt", Data("かな カナ".utf8)),
            ("濁点/\(nfdName)", Data("NFD source name stored as NFC".utf8)),
            ("絵文字/🎈🎁.txt", Data("emoji names".utf8)),
            ("empty.dat", Data()),
            ("random-1mb.bin", pseudoRandom(1 << 20)),
        ]
        for (name, data) in cases {
            try makeFile(name, data: data, in: src)
        }
        // The junk filter must drop these. (`._` AppleDouble files are
        // additionally hidden by Foundation's directory enumeration on this
        // macOS, so only .DS_Store shows up in the reported count; the
        // leak check below covers both.)
        try makeFile(".DS_Store", data: Data("junk".utf8), in: src)
        try makeFile("._readme.txt", data: Data("junk".utf8), in: src)

        let zipURL = work.appendingPathComponent("日本語アーカイブ.zip")
        let packResult = try Packer.pack([src], to: zipURL)
        try assert(packResult.excludedJunk.contains("入力/.DS_Store"),
                   "macOS junk not excluded: \(packResult.excludedJunk)")

        let reader = try ZipReader(url: zipURL)
        let entryNames = Set(reader.entries.map(\.name))
        for (name, _) in cases {
            let expected = "入力/" + FileNameEncoding.nfc(name)
            try assert(entryNames.contains(expected), "entry missing from archive: \(expected)")
        }
        try assert(!entryNames.contains(where: { $0.contains(".DS_Store") || $0.contains("._readme") }),
                   "junk leaked into the archive")
        for entry in reader.entries {
            let nfc = entry.name.precomposedStringWithCanonicalMapping
            try assert(nfc == entry.name, "entry name not NFC: \(entry.name)")
        }
        // Non-ASCII names must carry the UTF-8 flag (bit 11).
        let nonASCII = reader.entries.filter { $0.name.contains(where: { $0.asciiValue == nil }) }
        try assert(!nonASCII.isEmpty, "no non-ASCII entries to check")
        try assert(nonASCII.allSatisfy(\.isUTF8Flagged), "non-ASCII entry without the UTF-8 flag")

        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let result = try Unpacker.unpack(zipURL: zipURL, options: .init(destination: outDir))
        try assert(result.skippedUnsafe.isEmpty, "unexpected unsafe skips: \(result.skippedUnsafe)")
        for (name, data) in cases {
            let path = "入力/" + FileNameEncoding.nfc(name)
            let extracted = contents(path, in: outDir)
            try assert(extracted != nil, "not extracted: \(path)")
            try assert(extracted! == data,
                       "content mismatch: \(path) sha \(sha256(extracted!)) != \(sha256(data))")
        }
    }

    /// The CP932 option writes legacy-compatible names with the flag unset,
    /// and refuses (rather than mangles) unmappable names.
    public static func cp932Write() throws {
        let work = tempDir("cp932write")
        defer { try? FileManager.default.removeItem(at: work) }
        let src = work.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeFile("資料.txt", data: Data("本文".utf8), in: src)

        let zipURL = work.appendingPathComponent("legacy.zip")
        _ = try Packer.pack([src], to: zipURL, options: .init(nameEncoding: .cp932))

        let raw = try Data(contentsOf: zipURL)
        let reader = try ZipReader(url: zipURL)
        let entry = reader.entries.first { $0.name.hasSuffix(".txt") }
        try assert(entry != nil, "entry not found in CP932 archive")
        try assert(entry!.isUTF8Flagged == false, "CP932 entry must not set the UTF-8 flag")
        try assert(entry!.nameBytes == "src/資料.txt".data(using: FileNameEncoding.cp932),
                   "raw name bytes are not CP932")
        try assert(raw.range(of: Data("src/資料.txt".utf8)) == nil,
                   "UTF-8 name bytes leaked into a CP932 archive")

        // Unmappable character (emoji) must stop the write, not mangle it.
        let emojiDir = work.appendingPathComponent("emoji", isDirectory: true)
        try FileManager.default.createDirectory(at: emojiDir, withIntermediateDirectories: true)
        try makeFile("🎈.txt", data: Data(count: 1), in: emojiDir)
        let badZip = work.appendingPathComponent("bad.zip")
        do {
            _ = try Packer.pack([emojiDir], to: badZip, options: .init(nameEncoding: .cp932))
            throw ScenarioFailure(message: "CP932 write of an emoji name unexpectedly succeeded")
        } catch let error as DizunError {
            guard case .nameNotEncodable = error else {
                throw ScenarioFailure(message: "wrong error for unmappable name: \(error)")
            }
        }
        try assert(!exists(badZip), "failed CP932 pack left an archive behind")
    }

    /// Legacy Windows ZIPs: CP932 names without the flag are auto-detected.
    public static func cp932ReadAutoDetect() throws {
        let work = tempDir("cp932read")
        defer { try? FileManager.default.removeItem(at: work) }
        let names = ["資料/報告書.txt", "表.txt", "メモ.md"]
        var entries: [ZipCraft.EntrySpec] = []
        var expected: [String: Data] = [:]
        for name in names {
            let data = Data("内容-\(name)".utf8)
            expected[name] = data
            entries.append(ZipCraft.EntrySpec(
                nameBytes: name.data(using: FileNameEncoding.cp932)!,
                utf8Flag: false, payload: data))
        }
        let zipURL = work.appendingPathComponent("win.zip")
        try ZipCraft.archive(entries).write(to: zipURL)

        let reader = try ZipReader(url: zipURL)
        try assert(reader.detectedEncoding == .cp932,
                   "detection picked \(reader.detectedEncoding) for CP932 names")
        for entry in reader.entries {
            try assert(expected[entry.name] != nil, "CP932 name decoded wrong: \(entry.name)")
        }

        let outDir = work.appendingPathComponent("out", isDirectory: true)
        var options = Unpacker.Options()
        options.destination = outDir
        options.folderPolicy = .never
        let result = try Unpacker.unpack(zipURL: zipURL, options: options)
        try assert(result.detectedEncoding == .cp932, "unpack detection mismatch")
        for (name, data) in expected {
            let extracted = contents(name, in: outDir)
            try assert(extracted == data, "CP932 round trip corrupted: \(name)")
        }
    }

    /// Existing files are never overwritten: content survives, the archive's
    /// copy lands under a numbered name.
    public static func overwritePrevention() throws {
        let work = tempDir("overwrite")
        defer { try? FileManager.default.removeItem(at: work) }
        let original = Data("既存の内容".utf8)
        let updated = Data("新しい内容".utf8)
        try makeFile("data.txt", data: original, in: work)
        let zipURL = work.appendingPathComponent("dup.zip")
        try ZipCraft.archive([ZipCraft.EntrySpec(name: "data.txt", payload: updated)])
            .write(to: zipURL)

        var options = Unpacker.Options()
        options.destination = work
        options.folderPolicy = .never
        _ = try Unpacker.unpack(zipURL: zipURL, options: options)
        try assert(try Data(contentsOf: work.appendingPathComponent("data.txt")) == original,
                   "existing file was overwritten")
        try assert((try? Data(contentsOf: work.appendingPathComponent("data 2.txt"))) == updated,
                   "archive copy did not land under a numbered name")
    }

    /// Case-fold and NFC collisions both produce numbered variants.
    public static func collisions() throws {
        let work = tempDir("collisions")
        defer { try? FileManager.default.removeItem(at: work) }
        let zipData = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "A.txt", payload: Data("a".utf8)),
            ZipCraft.EntrySpec(name: "a.txt", payload: Data("b".utf8)),
            ZipCraft.EntrySpec(name: "テ\u{3099}ータ.txt", payload: Data("nfd".utf8)),  // decomposed
            ZipCraft.EntrySpec(name: "データ.txt", payload: Data("nfc".utf8)),          // precomposed
        ])
        let zipURL = work.appendingPathComponent("collide.zip")
        try zipData.write(to: zipURL)
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        var options = Unpacker.Options()
        options.destination = outDir
        options.folderPolicy = .never
        let result = try Unpacker.unpack(zipURL: zipURL, options: options)
        try assert(result.renamedDuplicates.count == 2,
                   "expected 2 renamed duplicates, got \(result.renamedDuplicates)")

        let children = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        try assert(children.count == 4, "expected 4 files, got \(children)")
        let folded = Set(children.map {
            $0.precomposedStringWithCanonicalMapping.lowercased()
        })
        try assert(folded == ["a.txt", "a 2.txt", "データ.txt", "データ 2.txt"],
                   "unexpected collision outcome: \(children.sorted())")
    }

    /// Hostile paths never escape the destination.
    public static func zipSlip() throws {
        let work = tempDir("zipslip")
        defer { try? FileManager.default.removeItem(at: work) }
        let hostile = ["../evil.txt", "/absolute.txt", "C:\\drive.txt",
                       "good/../../../escape.txt", "stream:ads.txt", "..\\win\\up.txt"]
        let entries = hostile.map {
            ZipCraft.EntrySpec(name: $0, payload: Data("x".utf8))
        } + [ZipCraft.EntrySpec(name: "good/safe.txt", payload: Data("ok".utf8))]
        let zipURL = work.appendingPathComponent("hostile.zip")
        try ZipCraft.archive(entries).write(to: zipURL)

        let dest = work.appendingPathComponent("dest", isDirectory: true)
        var options = Unpacker.Options()
        options.destination = dest
        options.folderPolicy = .never
        let result = try Unpacker.unpack(zipURL: zipURL, options: options)
        try assert(result.skippedUnsafe.count == hostile.count,
                   "expected \(hostile.count) unsafe skips, got \(result.skippedUnsafe)")
        try assert(contents("good/safe.txt", in: dest) == Data("ok".utf8), "safe entry not extracted")
        try assert(!exists(work.appendingPathComponent("evil.txt")),
                   "zip-slip wrote outside the destination")
        let parentListing = try FileManager.default.contentsOfDirectory(atPath: work.path)
        try assert(!parentListing.contains("escape.txt") && !parentListing.contains("absolute.txt")
                   && !parentListing.contains("drive.txt") && !parentListing.contains("up.txt"),
                   "escaped file found in parent: \(parentListing)")
    }

    /// Symlink entries are skipped and reported.
    public static func symlinkSkipped() throws {
        let work = tempDir("symlink")
        defer { try? FileManager.default.removeItem(at: work) }
        let zipData = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "link", payload: Data("/etc/passwd".utf8),
                               unixMode: 0o120777),
            ZipCraft.EntrySpec(name: "real.txt", payload: Data("ok".utf8)),
        ])
        let zipURL = work.appendingPathComponent("sym.zip")
        try zipData.write(to: zipURL)
        let dest = work.appendingPathComponent("out", isDirectory: true)
        var options = Unpacker.Options()
        options.destination = dest
        options.folderPolicy = .never
        let result = try Unpacker.unpack(zipURL: zipURL, options: options)
        try assert(result.skippedSymlinks == ["link"],
                   "symlink not skipped: \(result.skippedSymlinks)")
        try assert(!exists(dest.appendingPathComponent("link")), "symlink was materialized")
    }

    /// Corruption is detected, never silently accepted.
    public static func corruption() throws {
        let work = tempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: work) }

        // Bad CRC.
        let badCRC = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "a.txt", payload: Data("hello".utf8), declaredCRC: 0xDEAD_BEEF),
        ])
        try expectUnpackError(badCRC, in: work, file: "crc.zip") { error in
            if case .crcMismatch = error { return true }
            return false
        }

        // Declared size lie (store entry, uncompressed larger than payload).
        let sizeLie = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "b.txt", payload: Data("tiny".utf8),
                               declaredUncompressed: 1 << 20),
        ])
        try expectUnpackError(sizeLie, in: work, file: "size.zip") { error in
            if case .sizeMismatch = error { return true }
            return false
        }

        // Unsupported compression method.
        let badMethod = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "c.txt", method: 12, payload: Data([1, 2, 3])),
        ])
        try expectUnpackError(badMethod, in: work, file: "method.zip") { error in
            if case .unsupportedMethod(12, _) = error { return true }
            return false
        }

        // Encrypted entry without a password: refused up front (crypto is
        // supported now — the refusal moved from 'unsupported' to the
        // password prompt path).
        var encrypted = ZipCraft.archive([ZipCraft.EntrySpec(name: "d.txt", payload: Data())])
        let flagsPosition = encrypted.count - 22 - (46 + 5) + 8
        encrypted[encrypted.startIndex + flagsPosition] = 0x01
        try expectUnpackError(encrypted, in: work, file: "enc.zip") { error in
            error == .passwordRequired
        }

        // Truncation: not a ZIP / corrupt.
        let whole = ZipCraft.archive([ZipCraft.EntrySpec(name: "e.txt", payload: Data("x".utf8))])
        let truncated = whole.prefix(whole.count - 10)
        do {
            _ = try ZipReader(data: Data(truncated))
            throw ScenarioFailure(message: "truncated archive parsed successfully")
        } catch let error as DizunError {
            try assert(error == .notAZip || isCorrupt(error),
                       "wrong error for truncated archive: \(error)")
        }

        // Local-header name differs from the central directory (overlap attack).
        let overlap = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "f.txt", payload: Data("x".utf8),
                               localNameOverride: Data("forged.txt".utf8)),
        ])
        let reader = try ZipReader(data: overlap)
        do {
            try reader.extract(reader.entries[0]) { _ in }
            throw ScenarioFailure(message: "forged local header accepted")
        } catch let error as DizunError {
            try assert(isCorrupt(error), "wrong error for forged local header: \(error)")
        }
    }

    static func isCorrupt(_ error: DizunError) -> Bool {
        if case .corrupt = error { return true }
        return false
    }

    static func expectUnpackError(_ zipData: Data, in work: URL, file: String,
                                  match: (DizunError) -> Bool) throws {
        let zipURL = work.appendingPathComponent(file)
        try zipData.write(to: zipURL)
        let dest = work.appendingPathComponent("out-\(file)", isDirectory: true)
        do {
            _ = try Unpacker.unpack(zipURL: zipURL, options: .init(destination: dest))
            throw ScenarioFailure(message: "\(file): unpack unexpectedly succeeded")
        } catch let error as DizunError {
            try assert(match(error), "\(file): wrong error: \(error)")
        }
    }

    /// Declared-total and expansion-ratio limits refuse bombs up front, and
    /// a legitimately compressible entry still passes at default settings.
    public static func zipBombGuards() throws {
        let work = tempDir("bomb")
        defer { try? FileManager.default.removeItem(at: work) }

        // (1) Declared total over the archive cap.
        let many = (0..<3).map { i in
            ZipCraft.EntrySpec(name: "f\(i).bin", payload: Data("x".utf8),
                               declaredUncompressed: 2 << 30)
        }
        try ZipCraft.archive(many).write(to: work.appendingPathComponent("over.zip"))
        var tight = Unpacker.Options()
        tight.limits.maxTotalUncompressed = 1 << 30
        do {
            _ = try Unpacker.unpack(zipURL: work.appendingPathComponent("over.zip"), options: tight)
            throw ScenarioFailure(message: "declared-total bomb accepted")
        } catch let error as DizunError {
            try assert(isLimit(error), "wrong error for total-size bomb: \(error)")
        }

        // (2) Per-entry expansion ratio: 1 MiB of zeros deflates ~1000:1,
        // far past a deliberately tight ratio cap.
        let zeros = Data(repeating: 0, count: 1 << 20)
        let deflatedZeros = ZipCraft.deflate(zeros)
        try ZipCraft.archive([
            ZipCraft.EntrySpec(name: "bomb.bin", method: 8, payload: deflatedZeros,
                               declaredUncompressed: UInt32(zeros.count),
                               declaredCRC: DizunCRC32.checksum(zeros)),
        ]).write(to: work.appendingPathComponent("ratio.zip"))
        var ratioOptions = Unpacker.Options()
        ratioOptions.limits.maxExpansionRatio = 10
        do {
            _ = try Unpacker.unpack(zipURL: work.appendingPathComponent("ratio.zip"),
                                    options: ratioOptions)
            throw ScenarioFailure(message: "ratio bomb accepted")
        } catch let error as DizunError {
            try assert(isLimit(error), "wrong error for ratio bomb: \(error)")
        }

        // (3) ~100:1 compressible data passes the default cap (200:1).
        let block = pseudoRandom(64 << 10)                     // 64 KiB block
        var repeated = Data(capacity: block.count * 100)
        for _ in 0..<100 { repeated.append(block) }
        let deflatedRepeated = ZipCraft.deflate(repeated)
        try ZipCraft.archive([
            ZipCraft.EntrySpec(name: "ok.bin", method: 8, payload: deflatedRepeated,
                               declaredUncompressed: UInt32(repeated.count),
                               declaredCRC: DizunCRC32.checksum(repeated)),
        ]).write(to: work.appendingPathComponent("ok.zip"))
        let dest = work.appendingPathComponent("ok-out", isDirectory: true)
        let result = try Unpacker.unpack(zipURL: work.appendingPathComponent("ok.zip"),
                                         options: .init(destination: dest))
        try assert(result.extractedFiles == 1, "legitimate compressible entry refused")
        try assert(contents("ok.bin", in: dest) == repeated, "compressible entry corrupted")
    }

    static func isLimit(_ error: DizunError) -> Bool {
        if case .limitExceeded = error { return true }
        return false
    }

    /// Cancellation removes everything this run created.
    public static func cancellationCleanup() throws {
        let work = tempDir("cancel")
        defer { try? FileManager.default.removeItem(at: work) }
        let zipData = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "first.txt", payload: Data("1".utf8)),
            ZipCraft.EntrySpec(name: "second.txt", payload: Data("2".utf8)),
        ])
        let zipURL = work.appendingPathComponent("cancel.zip")
        try zipData.write(to: zipURL)
        let dest = work.appendingPathComponent("out", isDirectory: true)
        do {
            _ = try Unpacker.unpack(zipURL: zipURL, options: .init(destination: dest),
                                    shouldCancel: { true })
            throw ScenarioFailure(message: "cancellation did not throw")
        } catch let error as DizunError {
            try assert(error == .cancelled, "wrong error on cancel: \(error)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        try assert(leftovers.isEmpty, "cancelled run left files: \(leftovers)")
    }

    /// The writer refuses duplicate names.
    public static func duplicateNames() throws {
        let work = tempDir("dup")
        defer { try? FileManager.default.removeItem(at: work) }
        let writer = try ZipWriter(url: work.appendingPathComponent("d.zip"))
        try writer.addFile("same.txt", data: Data("1".utf8))
        do {
            try writer.addFile("same.txt", data: Data("2".utf8))
            throw ScenarioFailure(message: "duplicate name accepted")
        } catch let error as DizunError {
            guard case .duplicateName = error else {
                throw ScenarioFailure(message: "wrong error for duplicate: \(error)")
            }
        }
    }

    /// An archive with no entries fails cleanly.
    public static func emptyArchive() throws {
        let work = tempDir("empty")
        defer { try? FileManager.default.removeItem(at: work) }
        let zipURL = work.appendingPathComponent("empty.zip")
        try ZipCraft.archive([]).write(to: zipURL)
        do {
            _ = try Unpacker.unpack(zipURL: zipURL, options: .init(
                destination: work.appendingPathComponent("out", isDirectory: true)))
            throw ScenarioFailure(message: "empty archive unpacked")
        } catch let error as Unpacker.Failure {
            try assert(error == .emptyArchive, "wrong failure for empty archive: \(error)")
        }
    }

    /// ZIP64 end records are honored when present.
    public static func zip64Read() throws {
        let work = tempDir("zip64")
        defer { try? FileManager.default.removeItem(at: work) }
        let data = Data("zip64 payload".utf8)
        let deflated = ZipCraft.deflate(data)
        try ZipCraft.archiveZip64([
            ZipCraft.EntrySpec(name: "big.bin", method: 8, payload: deflated,
                               declaredUncompressed: UInt32(data.count),
                               declaredCRC: DizunCRC32.checksum(data)),
        ]).write(to: work.appendingPathComponent("z64.zip"))
        let reader = try ZipReader(url: work.appendingPathComponent("z64.zip"))
        try assert(reader.entries.count == 1, "ZIP64 entry count wrong")
        try assert(reader.entries[0].name == "big.bin", "ZIP64 name wrong")
        var received = Data()
        try reader.extract(reader.entries[0]) { received.append($0) }
        try assert(received == data, "ZIP64 payload mismatch")
    }

    /// Files above `ZipWriter.inMemoryCompressLimit` take the streaming
    /// deflate path with CRC/size patch-back — this exercises it end to end.
    public static func streamingLargeFile() throws {
        let work = tempDir("stream")
        defer { try? FileManager.default.removeItem(at: work) }
        let payload = pseudoRandom(Int(ZipWriter.inMemoryCompressLimit) + (1 << 20))
        try payload.write(to: work.appendingPathComponent("large.bin"))
        let zipURL = work.appendingPathComponent("large.zip")
        _ = try Packer.pack([work.appendingPathComponent("large.bin")], to: zipURL)

        let reader = try ZipReader(url: zipURL)
        let entry = reader.entries.first { !$0.isDirectory }
        try assert(entry != nil, "streaming entry missing")
        try assert(entry!.method == Zip.methodDeflate, "large file not deflated")
        var received = Data()
        try reader.extract(entry!) { received.append($0) }
        try assert(received == payload, "streaming round trip corrupted (sha \(sha256(received)))")
    }

    /// macOS junk entries (`__MACOSX/`, `.DS_Store`, `._*`) are skipped and
    /// reported by default on extraction, kept when the option is off.
    public static func unpackJunkSkipped() throws {
        let work = tempDir("junkskip")
        defer { try? FileManager.default.removeItem(at: work) }
        let zipData = ZipCraft.archive([
            ZipCraft.EntrySpec(name: "real.txt", payload: Data("ok".utf8)),
            ZipCraft.EntrySpec(name: "__MACOSX/", payload: Data()),
            ZipCraft.EntrySpec(name: "__MACOSX/._real.txt", payload: Data("df".utf8)),
            ZipCraft.EntrySpec(name: "sub/.DS_Store", payload: Data("j".utf8)),
            ZipCraft.EntrySpec(name: "sub/._side", payload: Data("j".utf8)),
            ZipCraft.EntrySpec(name: "sub/keep.txt", payload: Data("keep".utf8)),
        ])
        let zipURL = work.appendingPathComponent("ditto-like.zip")
        try zipData.write(to: zipURL)

        let outDir = work.appendingPathComponent("out", isDirectory: true)
        var options = Unpacker.Options()
        options.destination = outDir
        options.folderPolicy = .never
        let result = try Unpacker.unpack(zipURL: zipURL, options: options)
        try assert(result.skippedJunk.count == 4,
                   "expected 4 junk skips, got \(result.skippedJunk)")
        try assert(!exists(outDir.appendingPathComponent("__MACOSX")), "__MACOSX extracted")
        try assert(!exists(outDir.appendingPathComponent("sub/.DS_Store")), ".DS_Store extracted")
        try assert(contents("real.txt", in: outDir) == Data("ok".utf8), "real entry missing")
        try assert(contents("sub/keep.txt", in: outDir) == Data("keep".utf8), "nested entry missing")

        // Opt-out keeps everything.
        var keepAll = Unpacker.Options()
        keepAll.destination = work.appendingPathComponent("keep", isDirectory: true)
        keepAll.folderPolicy = .never
        keepAll.skipMacJunk = false
        let kept = try Unpacker.unpack(zipURL: zipURL, options: keepAll)
        try assert(kept.skippedJunk.isEmpty, "opt-out still skipped junk")
        try assert(exists(work.appendingPathComponent("keep/__MACOSX/._real.txt")),
                   "opt-out did not keep __MACOSX")
    }

    /// AES-256 (WinZip AE-2) double-ZIP: structure hidden, entry metadata,
    /// password errors, and a byte-exact auto-unwrap round trip.
    public static func encryptedAESRoundTrip() throws {
        let work = tempDir("aes")
        defer { try? FileManager.default.removeItem(at: work) }
        // Compressible so the entry actually takes deflate under AES.
        let block = pseudoRandom(4 << 10)
        var payload = Data(capacity: block.count * 30)
        for _ in 0..<30 { payload.append(block) }
        let src = work.appendingPathComponent("機密資料", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeFile("秘密.txt", data: payload, in: src)
        try makeFile("空.txt", data: Data(), in: src)

        let zipURL = work.appendingPathComponent("secret.zip")
        _ = try Packer.pack([src], to: zipURL,
                            options: .init(encryption: .aes256(password: "test-パスワード123")))

        // The outer archive hides the structure: exactly one encrypted
        // entry, the inner ZIP, and the nested marker comment.
        let reader = try ZipReader(url: zipURL)
        try assert(reader.archiveComment == Packer.nestedArchiveComment,
                   "missing nested marker comment: \(reader.archiveComment ?? "nil")")
        let plainFiles = reader.entries.filter { !$0.isDirectory }
        try assert(plainFiles.count == 1, "outer should hold one entry, has \(plainFiles.count)")
        let outer = plainFiles[0]
        try assert(outer.name == "secret.zip", "inner entry name wrong: \(outer.name)")
        try assert(outer.isEncrypted, "outer entry missing the encrypted flag")
        try assert(outer.method == Zip.methodAES, "method should be 99, is \(outer.method)")
        try assert(outer.aesStrength == 3, "AES strength should be 3")
        try assert(outer.crc32 == 0, "AE-2 must store CRC 0")
        // Names hidden until decrypted.
        try assert(!reader.entries.contains { $0.name.contains("秘密") || $0.name.contains("空") },
                   "inner file names leaked into the outer directory")

        // No password → refused before anything is written.
        let out1 = work.appendingPathComponent("out1", isDirectory: true)
        do {
            _ = try Unpacker.unpack(zipURL: zipURL, options: .init(destination: out1))
            throw ScenarioFailure(message: "encrypted archive unpacked without a password")
        } catch let error as DizunError {
            try assert(error == .passwordRequired, "expected passwordRequired, got \(error)")
        }
        try assert((try? FileManager.default.contentsOfDirectory(atPath: out1.path)) == nil,
                   "password refusal left output behind")

        // Wrong password → rejected by the verifier/HMAC.
        do {
            _ = try Unpacker.unpack(zipURL: zipURL, options: .init(
                destination: work.appendingPathComponent("out2", isDirectory: true),
                password: "test-まちがい"))
            throw ScenarioFailure(message: "wrong password accepted")
        } catch let error as DizunError {
            guard case .wrongPassword = error else {
                throw ScenarioFailure(message: "expected wrongPassword, got \(error)")
            }
        }

        // Correct password → auto-unwrap → byte-exact, intermediate removed.
        let out3 = work.appendingPathComponent("out3", isDirectory: true)
        let result = try Unpacker.unpack(zipURL: zipURL, options: .init(
            destination: out3, password: "test-パスワード123"))
        try assert(result.extractedFiles == 2, "expected 2 files, got \(result.extractedFiles)")
        try assert(contents("機密資料/秘密.txt", in: out3) == payload,
                   "AES round trip corrupted the payload")
        try assert(contents("機密資料/空.txt", in: out3) == Data(),
                   "encrypted empty file corrupted")
        try assert(!exists(out3.appendingPathComponent("secret.zip")),
                   "inner intermediate left behind after unwrap")
    }

    /// PKWARE traditional (ZipCrypto): legacy framing, check byte, password
    /// errors, byte-exact round trip.
    public static func encryptedZipCryptoRoundTrip() throws {
        let work = tempDir("zcrypto")
        defer { try? FileManager.default.removeItem(at: work) }
        let payload = Data("レガシー暗号化のテスト。".utf8)
        let src = work.appendingPathComponent("資料", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeFile("文書.txt", data: payload, in: src)

        let zipURL = work.appendingPathComponent("legacy.zip")
        _ = try Packer.pack([src], to: zipURL,
                            options: .init(encryption: .zipCrypto(password: "test-pw-1234")))

        // Double-ZIP outer: one encrypted entry, marker comment, names hidden.
        let reader = try ZipReader(url: zipURL)
        try assert(reader.archiveComment == Packer.nestedArchiveComment,
                   "missing nested marker comment")
        let plainFiles = reader.entries.filter { !$0.isDirectory }
        try assert(plainFiles.count == 1, "outer should hold one entry")
        let entry = plainFiles[0]
        try assert(entry.name == "legacy.zip", "inner entry name wrong: \(entry.name)")
        try assert(entry.isEncrypted, "missing encrypted flag")
        try assert(entry.encryptionKind == .zipCrypto, "kind should be zipCrypto")
        try assert(entry.crc32 != 0, "ZipCrypto keeps the real CRC")
        try assert(!reader.entries.contains { $0.name.contains("文書") },
                   "inner file names leaked into the outer directory")

        do {
            _ = try Unpacker.unpack(zipURL: zipURL, options: .init(
                destination: work.appendingPathComponent("out1", isDirectory: true)))
            throw ScenarioFailure(message: "unpacked without password")
        } catch let error as DizunError {
            try assert(error == .passwordRequired, "expected passwordRequired, got \(error)")
        }
        do {
            _ = try Unpacker.unpack(zipURL: zipURL, options: .init(
                destination: work.appendingPathComponent("out2", isDirectory: true),
                password: "test-bad"))
            throw ScenarioFailure(message: "wrong password accepted")
        } catch let error as DizunError {
            guard case .wrongPassword = error else {
                throw ScenarioFailure(message: "expected wrongPassword, got \(error)")
            }
        }

        // Correct password → auto-unwrap, intermediate removed.
        let out3 = work.appendingPathComponent("out3", isDirectory: true)
        _ = try Unpacker.unpack(zipURL: zipURL, options: .init(
            destination: out3, password: "test-pw-1234"))
        try assert(contents("資料/文書.txt", in: out3) == payload,
                   "ZipCrypto round trip corrupted the payload")
        try assert(!exists(out3.appendingPathComponent("legacy.zip")),
                   "inner intermediate left behind after unwrap")
    }

    public static let all: [(name: String, run: () throws -> Void)] = [
        ("roundTripJapanese", roundTripJapanese),
        ("cp932Write", cp932Write),
        ("cp932ReadAutoDetect", cp932ReadAutoDetect),
        ("overwritePrevention", overwritePrevention),
        ("collisions", collisions),
        ("zipSlip", zipSlip),
        ("symlinkSkipped", symlinkSkipped),
        ("corruption", corruption),
        ("zipBombGuards", zipBombGuards),
        ("cancellationCleanup", cancellationCleanup),
        ("duplicateNames", duplicateNames),
        ("emptyArchive", emptyArchive),
        ("zip64Read", zip64Read),
        ("streamingLargeFile", streamingLargeFile),
        ("unpackJunkSkipped", unpackJunkSkipped),
        ("encryptedAESRoundTrip", encryptedAESRoundTrip),
        ("encryptedZipCryptoRoundTrip", encryptedZipCryptoRoundTrip),
    ]
}
