import CArchive

/// Multi-format engine over vendored libarchive (tar/7z/RAR/LZH).
public enum LibarchiveInfo {
    /// Version string of the vendored static build (for diagnostics only).
    public static var version: String { String(cString: archive_version_string()) }
}
