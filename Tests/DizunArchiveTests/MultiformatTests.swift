import DizunArchive
import Foundation
import XCTest

/// Multi-format scenarios over the vendored libarchive adapter: tar-family
/// round trips, 7z creation/extraction, detection, and the hostile-path
/// guards for the new containers.
final class MultiformatTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("dizun-mftests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// Source tree with Japanese names, a nested folder and enough bytes to
    /// exercise real compression.
    private func makeSource() throws -> URL {
        let src = work.appendingPathComponent("資料元", isDirectory: true)
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("フォルダ"), withIntermediateDirectories: true)
        try "日本語テキストの内容".data(using: .utf8)?
            .write(to: src.appendingPathComponent("報告書.txt"))
        try Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
            .write(to: src.appendingPathComponent("フォルダ").appendingPathComponent("data.bin"))
        return src
    }

    private func assertRoundTrip(_ format: ArchiveFormat,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let src = try makeSource()
        let output = work.appendingPathComponent("out." + format.commonExtensions[0].replacingOccurrences(of: ".", with: "_"))
        let wrote = try LibarchiveWriter.pack([src], to: output, format: format)
        XCTAssertGreaterThan(wrote.entryCount, 2, file: file, line: line)

        let listing = try LibarchiveArchive.list(url: output)
        XCTAssertEqual(listing.format, format, file: file, line: line)
        XCTAssertTrue(listing.entries.contains { $0.rawName.contains("報告書.txt") },
                      file: file, line: line)

        let outDir = work.appendingPathComponent("x-\(format.rawValue)")
        let outcome = try LibarchiveArchive.extract(url: output,
                                                    options: .init(destination: outDir))
        XCTAssertFalse(outcome.created.isEmpty, file: file, line: line)
        XCTAssertEqual(try folderHash(src), try folderHash(outDir.appendingPathComponent("資料元")),
                       "extracted bytes must match the source tree", file: file, line: line)
    }

    func testTarRoundTrip() throws { try assertRoundTrip(.tar) }
    func testTarGzRoundTrip() throws { try assertRoundTrip(.tarGz) }
    func testTarBz2RoundTrip() throws { try assertRoundTrip(.tarBz2) }
    func testTarXzRoundTrip() throws { try assertRoundTrip(.tarXz) }
    func testSevenZRoundTrip() throws { try assertRoundTrip(.sevenZ) }

    func testDetectionByMagic() throws {
        let src = try makeSource()
        let output = work.appendingPathComponent("m.tar.gz")
        _ = try LibarchiveWriter.pack([src], to: output, format: .tarGz)
        // A zip-named file holding tar.gz must still be detected as tar.
        let disguised = work.appendingPathComponent("fake.zip")
        try FileManager.default.copyItem(at: output, to: disguised)
        XCTAssertEqual(FormatDetector.detect(url: disguised), .gzipStream)
        XCTAssertEqual(LibarchiveArchive.resolveStream(.gzipStream, url: disguised), .tarGz)
    }

    func testStreamInsideIsResolvedAsTar() throws {
        let src = try makeSource()
        let output = work.appendingPathComponent("s.tgz")
        _ = try LibarchiveWriter.pack([src], to: output, format: .tarGz)
        XCTAssertEqual(LibarchiveArchive.resolveStream(.gzipStream, url: output), .tarGz)
    }

    func testHostilePathsRejected() throws {
        // Craft a tar with an absolute path and a `..` hop via the writer's
        // header emission path: write, then patch the first name field.
        let src = try makeSource()
        let output = work.appendingPathComponent("h.tar")
        _ = try LibarchiveWriter.pack([src], to: output, format: .tar)

        var bytes = try Data(contentsOf: output)
        func patch(name: String) {
            let field = name.data(using: .utf8)!
            for (i, b) in field.enumerated() { bytes[0 + i] = b }  // name field starts at 0
        }
        patch(name: "/etc/邪悪な場所/x.txt")
        let hostile1 = work.appendingPathComponent("h1.tar")
        try bytes.write(to: hostile1)
        XCTAssertThrowsError(try LibarchiveArchive.extract(url: hostile1, options: .init(destination: work)))

        var bytes2 = try Data(contentsOf: output)
        let dotdot = "../../脱出.txt".data(using: .utf8)!
        for (i, b) in dotdot.enumerated() { bytes2[i] = b }
        let hostile2 = work.appendingPathComponent("h2.tar")
        try bytes2.write(to: hostile2)
        XCTAssertThrowsError(try LibarchiveArchive.extract(url: hostile2, options: .init(destination: work)))
    }

    func testNoOverwriteExistingOutput() throws {
        let src = try makeSource()
        let output = work.appendingPathComponent("dup.tar.gz")
        _ = try LibarchiveWriter.pack([src], to: output, format: .tarGz)
        XCTAssertThrowsError(try LibarchiveWriter.pack([src], to: output, format: .tarGz))
    }

    /// Deep directory-equality by relative path + SHA-256.
    private func folderHash(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let items = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        for rel in items {
            let url = root.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let data = try Data(contentsOf: url)
            result[rel] = SHA256Hex.string(data)
        }
        return result
    }
}

import CryptoKit
private enum SHA256Hex {
    static func string(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension MultiformatTests {
    /// The user-visible contract: extracting where the same top-level
    /// folder (and files) already exist must never fail — the new items
    /// land under "name 2" and the existing ones stay untouched.
    func testExistingFolderGetsUniqueName() throws {
        let src = try makeSource()
        let output = work.appendingPathComponent("dup.tar.gz")
        _ = try LibarchiveWriter.pack([src], to: output, format: .tarGz)

        // First extraction creates 資料元/…; extract again into the same
        // destination — the second run must divert instead of erroring.
        let dest = work.appendingPathComponent("dest")
        let first = try LibarchiveArchive.extract(url: output, options: .init(destination: dest))
        XCTAssertTrue(first.renamedDuplicates.isEmpty)
        let before = try folderHash(dest)
        let second = try LibarchiveArchive.extract(url: output, options: .init(destination: dest))
        XCTAssertFalse(second.renamedDuplicates.isEmpty,
                       "second run must report the diverted top-level name")
        // The original items are untouched.
        XCTAssertEqual(before.filter { !$0.key.hasPrefix("資料元 2") },
                       try folderHash(dest).filter { !$0.key.hasPrefix("資料元 2") })
        // And the diverted copy has identical content.
        XCTAssertEqual(try folderHash(dest.appendingPathComponent("資料元")),
                       try folderHash(dest.appendingPathComponent("資料元 2")))
    }
}
