import Foundation

/// Entry-path sanitization and collision keys.
///
/// Rules follow the audited zip-porter hardening set (MIT, SHA 9868489):
/// backslashes count as separators (some Windows tools write them), absolute
/// paths, `..`, Windows drive prefixes and NTFS alternate data streams (`:`)
/// are rejected outright rather than rewritten.
public enum PathSafety {
    /// Split a decoded entry name into safe path components, or nil when the
    /// path must be rejected (the zip-slip guard).
    public static func sanitize(_ decodedName: String) -> [String]? {
        let unified = decodedName.replacingOccurrences(of: "\\", with: "/")
        if unified.hasPrefix("/") { return nil }
        var components: [String] = []
        for raw in unified.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(raw)
            if component == "." || component.isEmpty { continue }
            if component == ".." { return nil }
            if component.contains(":") { return nil }
            components.append(component)
        }
        return components.isEmpty ? nil : components
    }

    /// Collision key for case-insensitive, normalization-insensitive volumes:
    /// APFS (default) treats "Report.txt", "report.txt" and an NFD
    /// "データ.txt" as one file, so uniqueness must be decided on the folded
    /// key, not the raw name.
    public static func collisionKey(_ components: [String]) -> String {
        components.joined(separator: "/")
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
