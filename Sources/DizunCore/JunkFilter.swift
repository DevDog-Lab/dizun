import Foundation

/// macOS bookkeeping files that turn to garbage on Windows (SPEC §4): the
/// Creator writes them, ditto's `__MACOSX/` AppleDouble tree is the Reader's
/// counterpart. Shared by `Packer` (skip sources) and `Unpacker`
/// (skip entries) so both directions behave identically.
public enum JunkFilter {
    public static let names: Set<String> = [
        ".DS_Store", "__MACOSX", "Icon\r",
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
    ]

    /// Single-name check (case-insensitive for the fixed names).
    public static func isJunk(_ name: String) -> Bool {
        name.hasPrefix("._") || names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
    }

    /// Path-level check for extraction: any junk component marks the entry.
    public static func isJunkPath(_ components: [String]) -> Bool {
        components.contains { isJunk($0) }
    }
}
