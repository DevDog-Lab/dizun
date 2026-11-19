import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lossless-first image optimization (ImageOptim-equivalent behavior within
/// a zero-third-party-dependency budget — see
/// docs/IMAGE_OPTIMIZATION_PROPOSAL.md).
///
/// - PNG: ancillary text/EXIF chunks dropped (color-profile chunks kept),
///   IDAT recompressed at zlib level 9. Pixel scanlines are byte-identical.
/// - JPEG: EXIF/XMP/IPTC/comment segments dropped; the compressed scan data
///   is copied verbatim, so pixels are bit-identical. A non-identity EXIF
///   orientation is baked into the pixels (one re-encode) so portrait photos
///   do not come out sideways once the metadata is gone.
/// - Resize (optional, lossy): images larger than the limit are downscaled
///   on their long edge and re-encoded.
///
/// Replacement policy: a file is replaced only when the output is strictly
/// smaller, via exclusive temp + atomic rename. A `backup` closure runs
/// before the swap (the app layer moves the original to the Trash).
public enum ImageOptimizer {
    public struct Options: Sendable {
        /// Long-edge pixel cap for the web-oriented resize. nil = no resize.
        public var maxDimension: Int?
        /// Remove every metadata segment (EXIF incl. GPS, XMP, IPTC,
        /// comments). Color profiles survive; orientation is baked in.
        public var removeMetadata = true
        /// JPEG encode quality for the lossy paths (resize / orientation
        /// bake). 0.8 is visually transparent for web use.
        public var jpegQuality: Double = 0.8
        public init(maxDimension: Int? = nil, removeMetadata: Bool = true,
                    jpegQuality: Double = 0.8) {
            self.maxDimension = maxDimension
            self.removeMetadata = removeMetadata
            self.jpegQuality = jpegQuality
        }
    }

    public struct Result: Sendable {
        public let url: URL
        public let originalSize: Int
        public let optimizedSize: Int
        /// True when pixels were re-encoded (resize or orientation bake).
        public let reencoded: Bool
        /// True when the file was left untouched (unchanged, or the
        /// optimization did not shrink it).
        public let skipped: Bool
        public var savedBytes: Int { skipped ? 0 : originalSize - optimizedSize }
    }

    public enum Failure: Error, Equatable {
        case unsupportedFormat(String)
        case corrupt(String)
        case io(String)
    }

    /// png / jpg / jpeg — the formats phase 1 handles.
    public static func isSupported(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg": return true
        default: return false
        }
    }

    /// Optimize one file in place. `backup` runs after a smaller output has
    /// been verified and just before the swap; a thrown error aborts with
    /// the original untouched.
    public static func optimize(_ url: URL, options: Options = Options(),
                                backup: ((URL) throws -> Void)? = nil) throws -> Result {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        let originalSize = original.count
        guard originalSize > 0 else {
            throw Failure.corrupt("empty file: \(url.lastPathComponent)")
        }

        let output: Data
        var reencoded = false
        if original.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
            output = try optimizePNG(original, url: url, options: options, reencoded: &reencoded)
        } else if original.starts(with: Data([0xFF, 0xD8])) {
            output = try optimizeJPEG(original, url: url, options: options, reencoded: &reencoded)
        } else {
            throw Failure.unsupportedFormat(url.lastPathComponent)
        }

        // Never replace with something bigger (or merely equal).
        guard output.count < originalSize else {
            return Result(url: url, originalSize: originalSize,
                          optimizedSize: originalSize, reencoded: reencoded, skipped: true)
        }
        try verifyDecodable(output, url: url)

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".dizun-opt-\(UUID().uuidString).tmp")
        do {
            try output.write(to: temp)
            if let backup { try backup(url) }
            // The backup may have moved the original away (Trash); when it
            // did not, drop it here — the verified replacement is on disk.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw Failure.io("置き換えに失敗: \(url.lastPathComponent)")
        }
        return Result(url: url, originalSize: originalSize,
                      optimizedSize: output.count, reencoded: reencoded, skipped: false)
    }

    // MARK: - PNG

    /// Chunks color-critical for rendering — ancillary text/EXIF goes.
    static let pngKeepChunks: Set<String> = [
        "IHDR", "PLTE", "tRNS", "IDAT", "IEND",
        "sRGB", "iCCP", "gAMA", "cHRM", "cICP", "pHYs",
    ]

    static func optimizePNG(_ data: Data, url: URL, options: Options,
                            reencoded: inout Bool) throws -> Data {
        let chunks = try parsePNGChunks(data)
        guard chunks.contains(where: { $0.type == "IDAT" }) else {
            throw Failure.corrupt("PNG has no IDAT")
        }

        // Optional resize: decode-and-reencode, then the standard rebuild —
        // ImageIO's encoder adds its own ancillary chunks otherwise.
        if let maxDim = options.maxDimension, pngLongEdge(chunks) > maxDim {
            if let resized = reencode(url: url, maxDimension: maxDim, options: options),
               resized.count < data.count,
               let rebuilt = try? rebuildPNG(resized),
               rebuilt.count < data.count {
                reencoded = true
                return rebuilt
            }
        }

        return try rebuildPNG(data)
    }

    /// Lossless core: same scanlines, recompressed at level 9, ancillary
    /// text and EXIF chunks dropped.
    static func rebuildPNG(_ data: Data) throws -> Data {
        let chunks = try parsePNGChunks(data)
        guard chunks.contains(where: { $0.type == "IDAT" }) else {
            throw Failure.corrupt("PNG has no IDAT")
        }

        let raw = try inflateZlib(Data(chunks.filter { $0.type == "IDAT" }.map(\.data).joined()))
        let recompressed = try deflateZlib(raw, level: 9)
        // Sanity: the recompressed stream must decode back to identical bytes.
        guard try inflateZlib(recompressed) == raw else {
            throw Failure.corrupt("zlib round trip mismatch")
        }

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var idatEmitted = false
        for chunk in chunks where pngKeepChunks.contains(chunk.type) {
            if chunk.type == "IDAT" {
                if idatEmitted { continue }      // merge into one chunk
                idatEmitted = true
                appendChunk(&out, type: "IDAT", data: recompressed)
            } else {
                appendChunk(&out, type: chunk.type, data: chunk.data)
            }
        }
        return out
    }

    static func appendChunk(_ out: inout Data, type: String, data: Data) {
        out.append(u32(data.count))
        var body = Data(type.utf8)
        body.append(data)
        out.append(body)
        out.append(u32(Int(pngCRC(body))))
    }

    static func parsePNGChunks(_ data: Data) throws -> [(type: String, data: Data)] {
        var cursor = 8
        var chunks: [(type: String, data: Data)] = []
        while cursor + 8 <= data.count {
            let length = Int(readU32(data, at: cursor))
            let type = String(data: data.subdata(in: (cursor + 4)..<(cursor + 8)),
                              encoding: .ascii) ?? "\0"
            guard length >= 0, cursor + 12 + length <= data.count else {
                throw Failure.corrupt("PNG chunk structure broken")
            }
            chunks.append((type, data.subdata(in: (cursor + 8)..<(cursor + 8 + length))))
            if type == "IEND" {
                guard cursor + 12 + length == data.count else {
                    throw Failure.corrupt("trailing bytes after IEND")
                }
                return chunks
            }
            cursor += 12 + length
        }
        throw Failure.corrupt("PNG IEND missing")
    }

    static func pngLongEdge(_ chunks: [(type: String, data: Data)]) -> Int {
        guard let ihdr = chunks.first(where: { $0.type == "IHDR" }), ihdr.data.count >= 8 else { return 0 }
        return max(Int(readU32(ihdr.data, at: 0)), Int(readU32(ihdr.data, at: 4)))
    }

    // MARK: - JPEG

    /// Segments copied verbatim; EXIF APP1, XMP, APP13 IPTC, COM and other
    /// APPn dropped. The scan data after SOS is untouched, which is what
    /// makes this pixel-exact.
    static let jpegKeepMarkers: Set<UInt8> = [
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,     // SOF variants
        0xC4,                                   // DHT
        0xDB,                                   // DQT
        0xDD,                                   // DRI
        0xE0,                                   // APP0 (JFIF)
        0xE2,                                   // APP2 (ICC)
    ]

    static func optimizeJPEG(_ data: Data, url: URL, options: Options,
                             reencoded: inout Bool) throws -> Data {
        // Non-identity orientation must be baked in before the EXIF segment
        // goes, or portrait photos come out sideways. Same for a resize —
        // both take the re-encode path.
        let orientation = exifOrientationSegment(in: data)
        let needsResize = options.maxDimension.map { jpgLongEdge(data) > $0 } ?? false
        if orientation != nil || needsResize {
            let cap = needsResize ? options.maxDimension : nil
            if let rebuilt = reencode(url: url, maxDimension: cap, options: options),
               rebuilt.count < data.count,
               let stripped = try? stripJPEG(rebuilt),
               stripped.count < data.count {
                // ImageIO writes its own fresh EXIF on re-encode; strip it
                // so the output truly carries no metadata.
                reencoded = true
                return stripped
            }
            if orientation != nil {
                // Re-encoding did not shrink it; stripping the orientation
                // segment anyway would rotate the photo. Leave as-is.
                return data
            }
            // Resize did not pay off — plain strip below.
        }

        return try stripJPEG(data)
    }

    /// Copy the structural segments verbatim and drop EXIF/XMP/IPTC/COM;
    /// the scan data after SOS is untouched, which is what makes this
    /// pixel-exact.
    static func stripJPEG(_ data: Data) throws -> Data {

        var out = Data([0xFF, 0xD8])
        var cursor = 2
        while cursor + 4 <= data.count {
            guard data[data.startIndex + cursor] == 0xFF else {
                throw Failure.corrupt("JPEG marker expected")
            }
            let marker = data[data.startIndex + cursor + 1]
            if marker == 0xD9 || marker == 0xDA {         // copy the rest verbatim
                out.append(contentsOf: data[(data.startIndex + cursor)...])
                return out
            }
            let length = Int(readU16(data, at: cursor + 2))
            guard length >= 2, cursor + 2 + length <= data.count else {
                throw Failure.corrupt("JPEG segment length broken")
            }
            if jpegKeepMarkers.contains(marker) {
                out.append(contentsOf: data[(data.startIndex + cursor)..<(data.startIndex + cursor + 2 + length)])
            }
            cursor += 2 + length
        }
        throw Failure.corrupt("JPEG ended without scan data")
    }

    static func jpgLongEdge(_ data: Data) -> Int {
        var cursor = 2
        while cursor + 4 <= data.count {
            guard data[data.startIndex + cursor] == 0xFF else { return 0 }
            let marker = data[data.startIndex + cursor + 1]
            if marker == 0xD8 { cursor += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return 0 }
            let length = Int(readU16(data, at: cursor + 2))
            let sof = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if sof, length >= 7, cursor + 9 <= data.count {
                let height = Int(readU16(data, at: cursor + 5))
                let width = Int(readU16(data, at: cursor + 7))
                return max(width, height)
            }
            cursor += 2 + length
        }
        return 0
    }

    /// EXIF orientation (1..8) when a non-identity one is present — i.e.
    /// when dropping EXIF would rotate the displayed image.
    static func exifOrientationSegment(in data: Data) -> Int? {
        var cursor = 2
        while cursor + 4 <= data.count {
            guard data[data.startIndex + cursor] == 0xFF else { return nil }
            let marker = data[data.startIndex + cursor + 1]
            if marker == 0xD8 { cursor += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }
            let length = Int(readU16(data, at: cursor + 2))
            if marker == 0xE1, length > 10,
               data[data.startIndex + cursor + 4] == 0x45,
               data[data.startIndex + cursor + 5] == 0x78,
               data[data.startIndex + cursor + 6] == 0x69,
               data[data.startIndex + cursor + 7] == 0x66 {   // "Exif"
                return exifOrientationTag(
                    data.subdata(in: (data.startIndex + cursor + 10)..<(data.startIndex + cursor + 2 + length)))
            }
            cursor += 2 + length
        }
        return nil
    }

    /// Minimal TIFF walker for tag 0x0112. Nil for identity (1) or absent —
    /// callers only care when baking is needed.
    static func exifOrientationTag(_ tiff: Data) -> Int? {
        guard tiff.count >= 8 else { return nil }
        let little = tiff[tiff.startIndex] == 0x49
        func u16(_ o: Int) -> Int {
            little ? Int(tiff[tiff.startIndex + o]) | Int(tiff[tiff.startIndex + o + 1]) << 8
                   : Int(tiff[tiff.startIndex + o]) << 8 | Int(tiff[tiff.startIndex + o + 1])
        }
        func u32(_ o: Int) -> Int {
            var v = 0
            for i in 0..<4 {
                v = little ? v | Int(tiff[tiff.startIndex + o + i]) << (8 * i)
                           : v << 8 | Int(tiff[tiff.startIndex + o + i])
            }
            return v
        }
        let ifdOffset = u32(4)
        guard ifdOffset + 2 <= tiff.count else { return nil }
        let entries = u16(ifdOffset)
        for i in 0..<entries {
            let entry = ifdOffset + 2 + i * 12
            guard entry + 12 <= tiff.count else { return nil }
            if u16(entry) == 0x0112 {
                let value = u16(entry + 8)
                return value == 1 ? nil : value
            }
        }
        return nil
    }

    // MARK: - Shared re-encode (resize / orientation bake)

    /// Decode-and-reencode with ImageIO: bakes orientation, downscales to
    /// the long-edge cap (never upscales), writes no metadata at all.
    static func reencode(url: URL, maxDimension: Int?, options: Options) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,      // bakes orientation
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxDimension {
            thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = maxDimension
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let isPNG = url.pathExtension.lowercased() == "png"
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, (isPNG ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if !isPNG {
            properties[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The replacement must decode before anything overwrites the original.
    static func verifyDecodable(_ data: Data, url: URL) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw Failure.corrupt("optimized output does not decode: \(url.lastPathComponent)")
        }
    }
}

// MARK: - Byte helpers

func readU16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
}

func readU32(_ data: Data, at offset: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 { v = v << 8 | UInt32(data[data.startIndex + offset + i]) }
    return v
}

func u32(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
}

let pngCRCTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
    return c
}

func pngCRC(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in data { c = pngCRCTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}
