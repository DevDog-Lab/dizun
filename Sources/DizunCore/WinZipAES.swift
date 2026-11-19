import CommonCrypto
import Foundation

/// WinZip AES entry encryption (AE-1/AE-2, method 99 + extra field 0x9901):
/// PBKDF2-HMAC-SHA1 (1000 iterations), AES in CTR mode with a *little-
/// endian* counter starting at 1 (WinZip's variant, not NIST's), and an
/// HMAC-SHA1 authentication code (first 10 bytes) over the ciphertext.
/// Implementation from the WinZip AES specification; structure follows the
/// audited zip-porter design (MIT, SHA 9868489).
struct WinZipAES {
    static let authCodeSize = 10
    static let pbkdf2Iterations: UInt32 = 1000

    enum Strength: UInt8 {
        case aes128 = 1
        case aes192 = 2
        case aes256 = 3

        var keyBytes: Int {
            switch self {
            case .aes128: return 16
            case .aes192: return 24
            case .aes256: return 32
            }
        }

        var saltBytes: Int {
            switch self {
            case .aes128: return 8
            case .aes192: return 12
            case .aes256: return 16
            }
        }
    }

    enum Mode { case encrypt, decrypt }

    private let mode: Mode
    private var encKey: [UInt8]
    private var hmac = CCHmacContext()
    /// Derived alongside the keys; the writer stores it after the salt, the
    /// reader compares it — 16 bits of cheap wrong-password detection.
    let derivedVerifier: Data

    /// CTR state: next block number (starts at 1) and keystream bytes left
    /// over from the previous chunk.
    private var nextBlock: UInt64 = 1
    private var pendingKeystream: Data = Data()

    private init(password: String, strength: Strength, salt: Data, mode: Mode) {
        self.mode = mode
        let keyLen = strength.keyBytes
        var derived = [UInt8](repeating: 0, count: keyLen * 2 + 2)
        var passwordBytes = Array(password.utf8)
        salt.withUnsafeBytes { (saltRaw: UnsafeRawBufferPointer) in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes, passwordBytes.count,
                saltRaw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                Self.pbkdf2Iterations,
                &derived, derived.count)
        }
        encKey = Array(derived[0..<keyLen])
        var authKey = Array(derived[keyLen..<(keyLen * 2)])
        derivedVerifier = Data(derived[(keyLen * 2)...])
        CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), authKey, authKey.count)
        wipe(&authKey)
        wipe(&derived)
        wipe(&passwordBytes)
    }

    /// Decrypting init; nil when the stored verifier rejects the password
    /// (~1/65536 wrong passwords pass here and fail the HMAC instead).
    init?(password: String, strength: Strength, salt: Data, passwordVerifier: Data) {
        self.init(password: password, strength: strength, salt: salt, mode: .decrypt)
        guard derivedVerifier == passwordVerifier else { return nil }
    }

    /// Encrypting init; the caller supplies fresh random salt and stores
    /// `derivedVerifier` right after it.
    init(encryptWith password: String, strength: Strength, salt: Data) {
        precondition(salt.count == strength.saltBytes)
        self.init(password: password, strength: strength, salt: salt, mode: .encrypt)
    }

    // MARK: - Streaming

    /// Transform one chunk. HMAC always covers the ciphertext: input on
    /// decrypt, output on encrypt.
    mutating func process(_ chunk: Data) -> Data {
        if mode == .decrypt { hmacUpdate(chunk) }
        let out = ctrXOR(chunk)
        if mode == .encrypt { hmacUpdate(out) }
        return out
    }

    /// Decrypt side: constant-time compare against the entry's trailer.
    mutating func verifyAuthCode(_ trailer: Data) -> Bool {
        let mac = finalizeHMAC()
        guard trailer.count == Self.authCodeSize else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(mac.prefix(Self.authCodeSize), trailer) { diff |= a ^ b }
        return diff == 0
    }

    /// Encrypt side: the 10-byte code appended after the ciphertext.
    mutating func authCode() -> Data {
        finalizeHMAC().prefix(Self.authCodeSize)
    }

    // MARK: - Internals

    private mutating func hmacUpdate(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            CCHmacUpdate(&hmac, base, raw.count)
        }
    }

    private mutating func finalizeHMAC() -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmacFinal(&hmac, &mac)
        return Data(mac)
    }

    /// XOR with the AES-CTR keystream. Counter blocks are the block number
    /// as a little-endian 64-bit value followed by eight zero bytes.
    private mutating func ctrXOR(_ input: Data) -> Data {
        var out = Data(capacity: input.count)
        var index = input.startIndex

        while !pendingKeystream.isEmpty, index < input.endIndex {
            out.append(input[index] ^ pendingKeystream.removeFirst())
            index += 1
        }
        let remaining = input.distance(from: index, to: input.endIndex)
        guard remaining > 0 else { return out }

        let blocks = (remaining + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        for b in 0..<blocks {
            var n = (nextBlock + UInt64(b)).littleEndian
            withUnsafeBytes(of: &n) { counters.replaceSubrange(b * 16..<(b * 16 + 8), with: $0) }
        }
        nextBlock += UInt64(blocks)

        var keystream = [UInt8](repeating: 0, count: blocks * 16)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            encKey, encKey.count,
            nil,
            counters, counters.count,
            &keystream, keystream.count,
            &moved)
        precondition(status == kCCSuccess && moved == keystream.count, "AES keystream generation failed")

        var k = 0
        while index < input.endIndex {
            out.append(input[index] ^ keystream[k])
            index += 1
            k += 1
        }
        if k < keystream.count {
            pendingKeystream = Data(keystream[k...])
        }
        return out
    }
}

/// Best-effort scrub of buffers that held password-derived key material.
func wipe(_ bytes: inout [UInt8]) {
    _ = bytes.withUnsafeMutableBytes { raw in
        memset_s(raw.baseAddress, raw.count, 0, raw.count)
    }
    bytes.removeAll(keepingCapacity: false)
}
