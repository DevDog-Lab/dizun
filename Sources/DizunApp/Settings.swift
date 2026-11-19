import DizunCore
import Foundation

/// Persisted user choices (UserDefaults, suite for the app). Sparse on
/// purpose — only what genuinely varies between users (SPEC §5: encoding
/// ambiguity is a user decision, not a guess).
enum Settings {
    private static let defaults = UserDefaults.standard

    /// False (default): opening an archive shows the preview first. True:
    /// extract immediately, The-Unarchiver style.
    static var instantExtract: Bool {
        get { defaults.bool(forKey: "instantExtract") }
        set { defaults.set(newValue, forKey: "instantExtract") }
    }

    /// Name encoding used when creating ZIPs (CP932 for legacy Japanese
    /// Windows tools; unmappable names stop the write with an error).
    static var compressEncoding: ZipWriter.NameEncoding {
        get { defaults.string(forKey: "compressEncoding") == "cp932" ? .cp932 : .utf8 }
        set { defaults.set(newValue == .cp932 ? "cp932" : "utf8", forKey: "compressEncoding") }
    }

    /// Encryption used when creating ZIPs. The password itself is never
    /// persisted — only the chosen scheme; it is asked per job.
    static var compressEncryptionKind: EncryptionKind {
        get {
            switch defaults.string(forKey: "compressEncryption") {
            case "aes256": return .aes256
            case "zipcrypto": return .zipCrypto
            default: return .none
            }
        }
        set {
            let raw: String
            switch newValue {
            case .none: raw = "none"
            case .aes256: raw = "aes256"
            case .zipCrypto: raw = "zipcrypto"
            }
            defaults.set(raw, forKey: "compressEncryption")
        }
    }

    /// Long-edge cap for the web resize on image optimization (nil = none).
    static var optimizeMaxDimension: Int? {
        get {
            let raw = defaults.integer(forKey: "optimizeMaxDimension")
            return raw > 0 ? raw : nil
        }
        set {
            defaults.set(newValue ?? 0, forKey: "optimizeMaxDimension")
        }
    }

    /// Keep the pre-optimization original in the Trash (recommended).
    static var optimizeBackupToTrash: Bool {
        get { defaults.object(forKey: "optimizeBackupToTrash") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "optimizeBackupToTrash") }
    }

    enum EncryptionKind {
        case none
        case aes256
        case zipCrypto

        var label: String {
            switch self {
            case .none: return "暗号化なし"
            case .aes256: return "AES-256"
            case .zipCrypto: return "ZipCrypto（旧方式・弱い）"
            }
        }
    }
}
