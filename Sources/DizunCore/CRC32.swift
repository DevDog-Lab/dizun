import Foundation

/// Public CRC-32 (IEEE) facade for tooling, the CLI and test fixtures.
public enum DizunCRC32 {
    public static func checksum(_ data: Data) -> UInt32 { CRC32.checksum(data) }
}

/// CRC-32 (IEEE 802.3, the ZIP polynomial 0xEDB88320). ZIP stores this per entry.
enum CRC32 {
    /// The register starts pre-conditioned to all-ones (standard CRC-32);
    /// `finalize` XORs it back out. Verified against Info-ZIP unzip.
    static let initial: UInt32 = 0xFFFF_FFFF

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// Running update on the raw register; start from `initial`.
    static func update(_ crc: inout UInt32, _ data: Data) {
        var c = crc
        for byte in data {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        crc = c
    }

    static func finalize(_ crc: UInt32) -> UInt32 { crc ^ 0xFFFF_FFFF }

    static func checksum(_ data: Data) -> UInt32 {
        var c = initial
        update(&c, data)
        return finalize(c)
    }
}
