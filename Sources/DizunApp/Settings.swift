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
}
