import CoreGraphics
import DizunImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image-optimizer verification scenarios (phase 1). Same contract as the
/// ZIP scenarios: throw on failure, shared by XCTest and `dizun selftest`.
enum ImageScenarios {
    static func assert(_ condition: Bool, _ message: String) throws {
        if !condition { throw Scenarios.ScenarioFailure(message: message) }
    }

    static let exifHeader = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])   // "Exif\0\0"

    static func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dizun-img-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Image builders

    /// Incompressible noise (photo-worst-case): re-encoding at lower
    /// quality or fewer pixels is *always* smaller for this content, which
    /// is what the re-encode scenarios need. Gradients would shrink to
    /// almost nothing and can make a 3000px original beat a 1280px copy.
    static func makeNoiseImage(width: Int, height: Int) -> CGImage {
        var state: UInt64 = 0x44495A554E
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
        defer { buffer.deallocate() }
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8(truncatingIfNeeded: state >> 33)
            buffer.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
            buffer.storeBytes(of: value, toByteOffset: offset + 1, as: UInt8.self)
            buffer.storeBytes(of: value, toByteOffset: offset + 2, as: UInt8.self)
            buffer.storeBytes(of: UInt8(255), toByteOffset: offset + 3, as: UInt8.self)
        }
        let ctx = CGContext(data: buffer, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Photo-ish gradient: compressible but not trivial.
    static func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                let r = CGFloat((x * 5) % 256) / 255
                let g = CGFloat((y * 3 + x) % 256) / 255
                let b = CGFloat((x * x + y) % 256) / 255
                ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL,
                         properties: [CFString: Any] = [:]) throws -> Data {
        try write(image, to: url, type: .png, properties: properties)
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL,
                          properties: [CFString: Any] = [:]) throws -> Data {
        try write(image, to: url, type: .jpeg, properties: properties)
    }

    static func write(_ image: CGImage, to url: URL, type: UTType,
                      properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var props = properties
        if type == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        try (data as Data).write(to: url)
        return data as Data
    }

    /// Append a padded tEXt chunk to a PNG (simulates metadata bloat),
    /// keeping the real IEND (with its fixed CRC) at the end. The length
    /// field counts the data section only, per the PNG specification.
    static func appendTextChunk(to png: URL, keyword: String, padding: Int) throws {
        var data = try Data(contentsOf: png)
        let iend = data.suffix(12)
        data.removeSubrange((data.count - 12)..<data.count)
        let payload = Data(keyword.utf8) + Data([0]) + Data(repeating: 0x78, count: padding)
        var body = Data("tEXt".utf8)
        body.append(payload)
        var chunk = Data()
        chunk.append(withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) })
        chunk.append(body)
        chunk.append(withUnsafeBytes(of: pngCRC(body)) { Data($0) })
        data.append(chunk)
        data.append(iend)
        try data.write(to: png)
    }

    static func pngCRC(_ data: Data) -> UInt32 {
        let table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Decode without applying EXIF orientation (raw stored pixels).
    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Render to RGBA bytes for comparison.
    static func render(_ image: CGImage) -> Data {
        let width = image.width, height = image.height
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.data.map { Data(bytes: $0, count: width * height * 4) } ?? Data()
    }

    static func pixelsEqual(_ a: URL, _ b: URL) -> Bool {
        guard let imageA = decode(a), let imageB = decode(b) else { return false }
        guard imageA.width == imageB.width, imageA.height == imageB.height else { return false }
        return render(imageA) == render(imageB)
    }

    static func longEdge(_ url: URL) -> Int {
        guard let image = decode(url) else { return 0 }
        return max(image.width, image.height)
    }

    // MARK: - Scenarios

    /// PNG: ancillary text dropped, IDAT recompressed, pixels identical.
    static func pngLossless() throws {
        let work = tempDir("png")
        defer { try? FileManager.default.removeItem(at: work) }
        let ref = work.appendingPathComponent("ref.png")
        try writePNG(makeImage(width: 400, height: 300), to: ref)
        try appendTextChunk(to: ref, keyword: "Comment", padding: 80_000)

        let url = work.appendingPathComponent("写真.png")
        try Data(contentsOf: ref).write(to: url)
        let paddedSize = try Data(contentsOf: url).count

        let result = try ImageOptimizer.optimize(url)
        try assert(!result.skipped, "PNG should have shrunk")
        try assert(!result.reencoded, "plain PNG must stay lossless")
        let optimized = try Data(contentsOf: url)
        try assert(optimized.count < paddedSize - 60_000, "padding not removed")
        try assert(optimized.range(of: Data("Comment".utf8)) == nil, "tEXt payload survived")
        try assert(pixelsEqual(ref, url), "pixels changed during lossless optimization")
    }

    /// JPEG: EXIF/GPS removed, scan data byte-identical.
    static func jpegMetadataStripped() throws {
        let work = tempDir("jpg")
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appendingPathComponent("photo.jpg")
        let original = try writeJPEG(makeImage(width: 320, height: 240), to: url, properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "dizun-test",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6,
                kCGImagePropertyGPSLatitudeRef: "N",
            ] as [CFString: Any],
        ])
        try assert(original.range(of: exifHeader) != nil, "fixture failed to embed EXIF")

        let result = try ImageOptimizer.optimize(url)
        let optimized = try Data(contentsOf: url)
        try assert(!result.skipped, "JPEG should have shrunk")
        try assert(!result.reencoded, "identity-orientation JPEG must not re-encode")
        try assert(optimized.range(of: exifHeader) == nil, "Exif header survived")
        // Pixel-exactness: the scan from SOS onward is copied verbatim.
        guard let scanA = original.range(of: Data([0xFF, 0xDA])),
              let scanB = optimized.range(of: Data([0xFF, 0xDA])) else {
            throw Scenarios.ScenarioFailure(message: "SOS missing")
        }
        try assert(original[scanA] == optimized[scanB],
                   "compressed scan data changed in the lossless path")
    }

    /// Portrait orientation (EXIF 6) is baked in when EXIF goes: stored
    /// pixels get swapped, metadata gone, display orientation preserved.
    static func jpegOrientationBaked() throws {
        let work = tempDir("orient")
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appendingPathComponent("portrait.jpg")
        try writeJPEG(makeNoiseImage(width: 240, height: 320), to: url, properties: [
            kCGImagePropertyOrientation: 6,
        ])

        let result = try ImageOptimizer.optimize(url)
        let optimized = try Data(contentsOf: url)
        try assert(optimized.range(of: exifHeader) == nil, "Exif survived")
        if !result.skipped {
            try assert(result.reencoded, "orientation bake must re-encode")
            // Stored 240×320 with orientation 6 → baked 320×240.
            try assert(decode(url)?.width == 320 && decode(url)?.height == 240,
                       "orientation not baked into pixels")
        }
    }

    /// Web resize: long edge capped, small images untouched and lossless.
    static func webResize() throws {
        let work = tempDir("resize")
        defer { try? FileManager.default.removeItem(at: work) }
        let big = work.appendingPathComponent("big.png")
        try writePNG(makeNoiseImage(width: 3000, height: 2000), to: big)
        let result = try ImageOptimizer.optimize(big, options: .init(maxDimension: 1280))
        try assert(!result.skipped, "resize should always shrink a 3000px image")
        try assert(result.reencoded, "resize must re-encode")
        try assert(longEdge(big) == 1280, "long edge should be 1280, is \(longEdge(big))")

        // Under the cap: never upscaled, pixels untouched.
        let small = work.appendingPathComponent("small.png")
        try writePNG(makeImage(width: 300, height: 200), to: small)
        _ = try ImageOptimizer.optimize(small, options: .init(maxDimension: 1280))
        try assert(longEdge(small) == 300, "small image must not be upscaled")
    }

    /// The backup closure runs before replacement and keeps the original.
    static func backupKeepsOriginal() throws {
        let work = tempDir("backup")
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appendingPathComponent("img.png")
        try writePNG(makeImage(width: 500, height: 500), to: url)
        try appendTextChunk(to: url, keyword: "Junk", padding: 60_000)
        let padded = try Data(contentsOf: url)

        let backupDir = work.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var backedUp: URL?
        let result = try ImageOptimizer.optimize(url) { originalURL in
            let target = backupDir.appendingPathComponent(originalURL.lastPathComponent)
            try FileManager.default.moveItem(at: originalURL, to: target)
            backedUp = target
        }
        try assert(backedUp != nil, "backup closure never ran")
        try assert(!result.skipped, "expected shrink")
        try assert(try Data(contentsOf: backedUp!) == padded,
                   "backup does not hold the original bytes")
        try assert(try Data(contentsOf: url).count < padded.count, "replacement missing")
    }

    /// An already-optimal file is left completely untouched.
    static func noGrowNoTouch() throws {
        let work = tempDir("nogrow")
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appendingPathComponent("tiny.png")
        let original = try writePNG(makeImage(width: 4, height: 4), to: url)
        let result = try ImageOptimizer.optimize(url)
        if result.skipped {
            try assert(try Data(contentsOf: url) == original,
                       "skipped file must keep its exact bytes")
        }
    }
}
