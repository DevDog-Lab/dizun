import XCTest

@testable import DizunFixtures

/// Gate-B scenarios as XCTest cases. The scenarios themselves live in
/// DizunFixtures so `dizun selftest` can run the identical set where XCTest
/// is unavailable (see docs/BASELINE.md for the toolchain constraint).
final class DizunCoreTests: XCTestCase {
    func testRoundTripJapanese() throws { try Scenarios.roundTripJapanese() }
    func testCp932Write() throws { try Scenarios.cp932Write() }
    func testCp932ReadAutoDetect() throws { try Scenarios.cp932ReadAutoDetect() }
    func testOverwritePrevention() throws { try Scenarios.overwritePrevention() }
    func testCollisions() throws { try Scenarios.collisions() }
    func testZipSlip() throws { try Scenarios.zipSlip() }
    func testSymlinkSkipped() throws { try Scenarios.symlinkSkipped() }
    func testCorruption() throws { try Scenarios.corruption() }
    func testZipBombGuards() throws { try Scenarios.zipBombGuards() }
    func testCancellationCleanup() throws { try Scenarios.cancellationCleanup() }
    func testDuplicateNames() throws { try Scenarios.duplicateNames() }
    func testEmptyArchive() throws { try Scenarios.emptyArchive() }
    func testZip64Read() throws { try Scenarios.zip64Read() }
    func testStreamingLargeFile() throws { try Scenarios.streamingLargeFile() }
    func testUnpackJunkSkipped() throws { try Scenarios.unpackJunkSkipped() }
    func testEncryptedAESRoundTrip() throws { try Scenarios.encryptedAESRoundTrip() }
    func testEncryptedZipCryptoRoundTrip() throws { try Scenarios.encryptedZipCryptoRoundTrip() }
    func testImageOptimizePNG() throws { try ImageScenarios.pngLossless() }
    func testImageOptimizeJPEGStrip() throws { try ImageScenarios.jpegMetadataStripped() }
    func testImageOptimizeOrientationBake() throws { try ImageScenarios.jpegOrientationBaked() }
    func testImageOptimizeWebResize() throws { try ImageScenarios.webResize() }
    func testImageOptimizeBackup() throws { try ImageScenarios.backupKeepsOriginal() }
    func testImageOptimizeNoGrow() throws { try ImageScenarios.noGrowNoTouch() }
}
