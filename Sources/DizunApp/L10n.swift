import Foundation

/// In-app language selection. macOS resolves localization per-app at launch
/// only, so DIZUN keeps its own tiny string layer: every UI string goes
/// through `L10n`, and changing `Settings.language` rebuilds the affected
/// windows immediately (see AppDelegate's language-change observer).
enum AppLanguage: String, CaseIterable {
    case system
    case ja
    case en

    /// What the selector row shows (each name in its own language).
    var displayName: String {
        switch self {
        case .system: return L10n.systemSetting
        case .ja: return "日本語"
        case .en: return "English"
        }
    }

    /// `system` follows the OS list, falling back to Japanese.
    static func resolve(_ raw: String) -> AppLanguage {
        switch raw {
        case "ja", "en": return AppLanguage(rawValue: raw)!
        default:
            let preferred = Bundle.main.preferredLocalizations.first ?? "ja"
            return preferred == "en" ? .en : .ja
        }
    }

    var isEN: Bool { self == .en }
}

// MARK: - Strings

enum L10n {
    static var lang: AppLanguage = .system

    /// Call once at launch (and after a settings change) before building UI.
    static func refresh() {
        lang = AppLanguage.resolve(Settings.languageRaw)
    }

    // Shared
    static var systemSetting: String { lang.isEN ? "System" : "システム設定" }
    static var cancel: String { lang.isEN ? "Cancel" : "キャンセル" }
    static var extract: String { lang.isEN ? "Extract" : "解凍" }
    static var fileEncoding: String { lang.isEN ? "File-name encoding" : "ファイル名の文字コード" }

    // Droplet
    static var dropHere: String { lang.isEN ? "Drop here" : "ここにドロップ" }
    static var dropHint: String {
        lang.isEN ? "ZIP → extract · images → optimize · everything else → compress"
                  : "ZIPは解凍・画像は最適化・ほかは圧縮"
    }
    static var done: String { lang.isEN ? "Done" : "完了" }
    static var tabArchive: String { lang.isEN ? "Archive" : "圧縮・解凍" }
    static var tabImages: String { lang.isEN ? "Images" : "画像最適化" }
    static var archiveFileName: String { lang.isEN ? "Archive file name" : "圧縮時のファイル名" }
    static var archiveNameHint: String {
        lang.isEN ? "e.g. Report.zip — Archive.zip for multiple items"
                  : "例）報告書.zip ／ 複数なら Archive.zip"
    }
    static var utf8Standard: String { lang.isEN ? "UTF-8 (default)" : "UTF-8（標準）" }
    static var cp932Windows: String { lang.isEN ? "CP932 (Windows)" : "CP932（Windows互換）" }
    static var encryption: String { lang.isEN ? "Encryption" : "暗号化" }
    static var none: String { lang.isEN ? "None" : "なし" }
    static var nestedHint: String {
        lang.isEN ? "Nested ZIP hides the contents too" : "二重ZIPで構成も隠す"
    }
    static var longEdgeLimit: String { lang.isEN ? "Long-edge limit" : "長辺上限" }
    static var blankNoResize: String { lang.isEN ? "blank = no resize" : "空欄でリサイズなし" }
    static var targetSize: String { lang.isEN ? "Target size" : "目標サイズ" }
    static var kbOrLess: String { lang.isEN ? "KB or less" : "KB以下" }
    static var blankNone: String { lang.isEN ? "blank = none" : "空欄で指定なし" }
    static var originals: String { lang.isEN ? "Originals" : "元画像" }
    static var keepInTrash: String { lang.isEN ? "Keep in Trash" : "ゴミ箱へ残す" }

    // Settings
    static var settings: String { lang.isEN ? "Settings" : "設定" }
    static var imageDefaults: String { lang.isEN ? "Image optimization defaults" : "画像最適化の既定値" }
    static var language: String { lang.isEN ? "Language" : "言語" }

    // Menu
    static var aboutDizun: String { lang.isEN ? "About DIZUN" : "DIZUNについて" }
    static var settingsEllipsis: String { lang.isEN ? "Settings…" : "設定…" }
    static var services: String { lang.isEN ? "Services" : "サービス" }
    static var close: String { lang.isEN ? "Close" : "閉じる" }
    static var quitDizun: String { lang.isEN ? "Quit DIZUN" : "DIZUNを終了" }

    // About
    static var aboutTitle: String { lang.isEN ? "About DIZUN" : "DIZUNについて" }
    static func versionLine(_ version: String) -> String {
        lang.isEN ? "Version \(version) (in development, unreleased)"
                  : "バージョン \(version)（開発中・未リリース）"
    }
    static var aboutBlurb: String {
        lang.isEN
            ? "Archive and extract in one app for macOS, built around Japanese file names and Windows/macOS interoperability."
            : "圧縮と解凍をひとつにした、macOS向けアーカイブアプリ。日本語ファイル名とWindows/macOS間の互換性を重視します。"
    }
    static var openReadme: String { lang.isEN ? "Open GitHub README" : "GitHub README を開く" }

    // Work panel / prompts
    static var compressTitle: String { lang.isEN ? "Compress" : "圧縮" }
    static var optimizeTitle: String { lang.isEN ? "Optimize Images" : "画像最適化" }
    static var cancelling: String { lang.isEN ? "Cancelling…" : "キャンセルしています…" }
    static var problemTitle: String { lang.isEN ? "DIZUN ran into a problem" : "DIZUNで問題が起きました" }
    static var busyMessage: String {
        lang.isEN ? "Wait for the current job to finish." : "前の処理が終わってから実行してください。"
    }
    static var passwordRequired: String { lang.isEN ? "Password required" : "パスワードが必要です" }
    static func protectedArchive(_ name: String) -> String {
        lang.isEN ? "\"\(name)\" is password-protected" : "「\(name)」はパスワードで保護されています"
    }
    static var newPasswordTitle: String { lang.isEN ? "Set encryption password" : "暗号化パスワードを設定" }
    static var newPasswordInfo: String {
        lang.isEN
            ? "A nested ZIP also hides file names and structure. The password is never stored — without it, the contents cannot be recovered."
            : "二重ZIPでファイル名・構成も隠されます。パスワードはどこにも保存されません。忘れると内容を取り出せません。"
    }
    static var passwordField: String { lang.isEN ? "Password" : "パスワード" }
    static var passwordConfirm: String { lang.isEN ? "Confirm password" : "確認のためもう一度" }
    static var createEncrypted: String { lang.isEN ? "Create Encrypted" : "暗号化して作成" }
    static var passwordMismatch: String { lang.isEN ? "Passwords do not match" : "パスワードが一致しません" }
    static func setPasswordTitle(_ weak: Bool) -> String {
        lang.isEN ? "Set an encryption password (AES-256)"
                  : weak ? "暗号化パスワードを設定（ZipCrypto: 旧方式のため保護は弱いです）"
                         : "暗号化パスワードを設定（AES-256）"
    }

    // Results (drop area / notices)
    static func extractionDone(_ names: String, more: Int) -> String {
        let suffix = more > 0 ? (lang.isEN ? " +\(more) more" : " ほか\(more)件") : ""
        return lang.isEN ? "Extraction complete: \(names)\(suffix)" : "解凍完了：\(names)\(suffix)"
    }
    static func archiveDone(_ name: String, files: Int, size: String) -> String {
        lang.isEN ? "Archive complete: \(name) (\(files) files · \(size))"
                  : "圧縮完了：\(name)（\(files)ファイル・\(size)）"
    }
    static func optimizeDone(_ shrunk: Int, _ total: Int, _ saved: String) -> String {
        lang.isEN ? "Optimization complete (\(shrunk)/\(total) · \(saved) saved)"
                  : "最適化完了（\(shrunk)/\(total)枚・\(saved)減）"
    }
    static func optimizeLine(_ name: String, _ before: String, _ after: String, _ percent: Int) -> String {
        lang.isEN ? "\(name): \(before) → \(after) (\(percent)% smaller)"
                  : "\(name)：\(before) → \(after)（\(percent)%減）"
    }
    static var optimizeNoChange: String { lang.isEN ? "no change" : "縮小なし" }
    static func moreImages(_ count: Int) -> String {
        lang.isEN ? "+\(count) more" : "…ほか\(count)枚"
    }
    static func shrunkNotice(_ shrunk: Int, _ total: Int, _ saved: String) -> String {
        lang.isEN ? "\(shrunk)/\(total) images shrunk (\(saved) saved)"
                  : "\(shrunk)/\(total)枚を縮小（\(saved) 節約）"
    }
    static func nothingShrunk(_ count: Int) -> String {
        lang.isEN ? "Nothing to shrink (\(count) items). They may already be optimized, or smaller than the target size."
                  : "縮小できませんでした（\(count)枚）。すでに最適化されているか、目標サイズに対して画像が小さい可能性があります。"
    }

    // Preview
    static func encodingAuto(_ detected: String) -> String {
        lang.isEN ? "Auto (\(detected))" : "自動判定（\(detected)）"
    }
    static var detectedCP932: String { "CP932" }
    static var detectedUTF8: String { "UTF-8" }
    static var nameColumn: String { lang.isEN ? "Name" : "名前" }
    static var sizeColumn: String { lang.isEN ? "Size" : "サイズ" }
    static func summary(_ count: Int, _ size: String) -> String {
        lang.isEN ? "\(count) items · \(size)" : "\(count)項目・\(size)"
    }
    static func unsupportedWarning(_ count: Int) -> String {
        lang.isEN ? "\(count) item(s) use unsupported compression" : "未対応の圧縮方式の項目: \(count)件"
    }
    static func encryptedWarning(_ count: Int) -> String {
        lang.isEN ? "\(count) password-protected item(s) — asked at extraction" : "パスワード保護された項目: \(count)件（解凍時に尋ねます）"
    }
    static func notAZip(_ name: String) -> String {
        lang.isEN ? "Cannot read as a ZIP archive:\n\(name)" : "ZIPアーカイブとして読み込めません:\n\(name)"
    }
}
