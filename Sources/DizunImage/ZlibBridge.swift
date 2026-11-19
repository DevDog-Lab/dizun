import CZlib
import Foundation

/// zlib-format (RFC 1950) compress/decompress through the system zlib —
/// Apple ships it and its headers in the SDK; nothing is bundled (see
/// THIRD_PARTY_NOTICES). The Compression framework has no level control,
/// and PNG recompression wants level 9.
enum ZlibBridge {
    enum Failure: Error, Equatable {
        case inflateCorrupt
        case outOfMemory
    }

    static func deflateZlib(_ input: Data, level: Int32 = 9) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.outOfMemory
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 256 << 10
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = UInt32(raw.count)
            repeat {
                outBuffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    stream.next_out = raw.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = UInt32(chunkSize)
                }
                status = deflate(&stream, Z_FINISH)
                guard status != Z_STREAM_ERROR else { throw Failure.outOfMemory }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: outBuffer[0..<produced]) }
            } while status != Z_STREAM_END
        }
        return output
    }

    static func inflateZlib(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.outOfMemory
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 256 << 10
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = UInt32(raw.count)
            repeat {
                outBuffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    stream.next_out = raw.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = UInt32(chunkSize)
                }
                status = inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw Failure.inflateCorrupt
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: outBuffer[0..<produced]) }
            } while status != Z_STREAM_END && stream.avail_in > 0
        }
        guard status == Z_STREAM_END else { throw Failure.inflateCorrupt }
        return output
    }
}

func deflateZlib(_ input: Data, level: Int32 = 9) throws -> Data {
    try ZlibBridge.deflateZlib(input, level: level)
}

func inflateZlib(_ input: Data) throws -> Data {
    try ZlibBridge.inflateZlib(input)
}
