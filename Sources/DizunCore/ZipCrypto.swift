import Foundation

/// PKWARE "traditional" ZIP encryption (APPNOTE §6.1).
///
/// Cryptographically weak — known-plaintext attacks recover the keys — and
/// offered strictly for legacy compatibility (the scheme old Windows tools
/// and some appliance firmwares accept). Callers must warn when producing
/// it (SPEC §4). Algorithm per the PKWARE spec; implementation written from
/// the spec and the audited zip-porter design (MIT, SHA 9868489).
struct ZipCryptoCipher {
    static let headerSize = 12

    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    private mutating func update(with byte: UInt8) {
        key0 = Self.crc32Step(key0, byte)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.crc32Step(key2, UInt8(key1 >> 24))
    }

    private static func crc32Step(_ key: UInt32, _ byte: UInt8) -> UInt32 {
        CRC32.table[Int((key ^ UInt32(byte)) & 0xFF)] ^ (key >> 8)
    }

    private var keystreamByte: UInt8 {
        let temp = UInt16(key2 & 0xFFFF) | 2
        return UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
    }

    private init(password: String) {
        for byte in password.utf8 { update(with: byte) }
    }

    /// Decrypting init: consume the 12-byte encryption header and verify the
    /// check byte. Nil means the password is (almost certainly) wrong — the
    /// check is one byte, so 1/256 wrong passwords slip through here and
    /// fail the CRC later.
    init?(password: String, header: Data, checkByte: UInt8) {
        self.init(password: password)
        var last: UInt8 = 0
        for byte in header {
            last = byte ^ keystreamByte
            update(with: last)
        }
        guard last == checkByte else { return nil }
    }

    /// Encrypting init: emits the 12-byte header (11 random bytes + the
    /// check byte) into `out`.
    init(password: String, randomBytes: Data, checkByte: UInt8, header out: inout Data) {
        precondition(randomBytes.count == Self.headerSize - 1)
        self.init(password: password)
        for byte in randomBytes + [checkByte] {
            let encrypted = byte ^ keystreamByte
            update(with: byte)
            out.append(encrypted)
        }
    }

    mutating func decrypt(_ chunk: Data) -> Data {
        var out = Data(capacity: chunk.count)
        for byte in chunk {
            let plain = byte ^ keystreamByte
            update(with: plain)
            out.append(plain)
        }
        return out
    }

    mutating func encrypt(_ chunk: Data) -> Data {
        var out = Data(capacity: chunk.count)
        for byte in chunk {
            let encrypted = byte ^ keystreamByte
            update(with: byte)
            out.append(encrypted)
        }
        return out
    }
}
