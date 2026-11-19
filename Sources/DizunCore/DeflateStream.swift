import Compression
import Foundation

/// Public raw-DEFLATE facade for tooling, the CLI and test fixtures.
public enum DizunDeflate {
    public static func compress(_ data: Data) throws -> Data {
        try DeflateStream.compress(data)
    }

    /// `maxBytes` bounds the output (zip-bomb guard).
    public static func decompress(_ data: Data, maxBytes: UInt64) throws -> Data {
        try DeflateStream.decompress(data, maxBytes: maxBytes)
    }
}

/// Streaming raw-DEFLATE codec on Apple's Compression framework.
///
/// `COMPRESSION_ZLIB` there is *raw deflate* (no zlib header/trailer) — exactly
/// the stream ZIP stores in method-8 entries. This keeps DIZUN free of any C
/// dependency. (zip-porter's ADR-0003 chose system zlib for deflate instead,
/// to control the exact encoder; revisit if output determinism across macOS
/// releases ever becomes a requirement.)
enum DeflateStream {
    enum CodecError: Error, Sendable {
        case streamInitFailed
        case streamFailed
    }

    private static let bufferBytes = 256 * 1024

    /// Pull chunks from `read` (nil = end of input) and push output chunks to
    /// `write`. For decode, the caller enforces size limits inside `write`.
    static func run(encode: Bool,
                    read: () throws -> Data?,
                    write: (Data) throws -> Void) throws {
        let operation: compression_stream_operation =
            encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw CodecError.streamInitFailed
        }
        defer { compression_stream_destroy(&stream) }

        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferBytes)
        dst.deinitialize(count: bufferBytes)
        defer { dst.deallocate() }

        var finalized = false
        while !finalized {
            // Next input chunk (empty for the final flush).
            let chunk = try read() ?? Data()
            let isFinalInput = chunk.isEmpty
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    ?? UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_size = raw.count
                // A zero-length chunk means the source ran out: flush with FINALIZE.
                var flags: Int32 = 0
                if isFinalInput { flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue) }
                while true {
                    stream.dst_ptr = dst
                    stream.dst_size = bufferBytes
                    let status = compression_stream_process(&stream, flags)
                    guard status != COMPRESSION_STATUS_ERROR else { throw CodecError.streamFailed }
                    let produced = bufferBytes - stream.dst_size
                    if produced > 0 {
                        try write(Data(bytes: dst, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END {
                        // FINALIZE complete: the whole stream is emitted.
                        finalized = true
                        break
                    }
                    // OK with room left in dst means all input was consumed —
                    // go back for the next chunk; OK with a full dst loops here.
                    if stream.dst_size > 0 { break }
                }
            }
        }
    }

    /// One-shot in-memory convenience built on `run`.
    static func compress(_ data: Data) throws -> Data {
        var fed = false
        var out = Data()
        try run(encode: true, read: {
            if fed { return nil }
            fed = true
            return data.isEmpty ? nil : data
        }, write: { out.append($0) })
        return out
    }

    /// One-shot in-memory decompress. `maxBytes` bounds the output (zip-bomb guard).
    static func decompress(_ data: Data, maxBytes: UInt64) throws -> Data {
        var fed = false
        var out = Data()
        try run(encode: false, read: {
            if fed { return nil }
            fed = true
            return data.isEmpty ? nil : data
        }, write: { piece in
            guard UInt64(out.count) + UInt64(piece.count) <= maxBytes else {
                throw DizunError.limitExceeded("inflated output exceeds the safety cap")
            }
            out.append(piece)
        })
        return out
    }
}
