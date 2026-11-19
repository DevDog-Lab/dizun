# OSS監査 — Crate / zip-porter / libarchive

作成日: 2026-11-19
監査環境: macOS 27.2.1 (26B131) / Xcode 27.2 (27B52, ライセンス未同意のためCLTツールチェーンで代替検証) / CommandLineTools Swift 6.3.3 / cmake 4.4.4 (Homebrew)
監査者: Claude Code（Orcaオーケストレーション）
取得方法: `git clone` を `research/`（.gitignore管理外、コミット不含）へ実施し、以下のHEAD SHAで固定。

| リポジトリ | 固定SHA | 日付 | ライセンス |
| --- | --- | --- | --- |
| kleash/crate | `b2cb60120b5e1c581ff0cb51dabe4b6a2d63edca` | 2026-10-28 | MIT (Copyright (c) 2026 Shubham) |
| nlink-jp/zip-porter | `98684892dd266f1ca18f01ede91e829efe369c39` (v0.14.0) | 2026-11-01 | MIT (Copyright (c) 2026 nlink-jp) |
| libarchive/libarchive | `432ab464725aa99c53de7572979bd9bbbf382ed1` | 2026-11-16 | BSD-2-Clause系（ファイル単位で例外あり、COPYING記載） |

## 1. crate（kleash/crate）

- **構成**: SwiftPMパッケージ。`ArchiveCore`（libarchiveラッパー約955行）+ `Crate`（AppKit GUI実行可能ターゲット）+ `CrateQuickLook`（Quick Look拡張）。
- **依存関係**: サードパーティSwiftパッケージ**ゼロ**。macOS同梱のlibarchive（`archive_min.h`にlibarchive 3.7.4の宣言を手写ししたsystemLibrary経由）を使用。
- **機能**: ZIP/7z/RAR/TAR等の閲覧・解凍・作成、Finder Services（Compress with Crate / Extract Here）、Quick Look、分割ボリューム。
- **安全性**: 解凍はlibarchiveのdisk writerに `ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_UNLINK` を設定し、Swift側でも `..` 成分を検査。作成時のjunkファイル除外あり。umask競合対策など作り込みが見られる。
- **文字コード**: **CP932検出・変換の実装なし**。作成時に `zip:hdrcharset=UTF-8` を指定するのみ。読み取りはlibarchive既定の挙動に依存し、UTF-8フラグなしの日本語Windows製ZIP（CP932）のファイル名は文字化けする可能性が高い。**DIZUNの中核課題を解決しない。**
- **リスク**:
  - macOS同梱libarchiveへの依存。Appleの更新タイミング・バージョンは制御できず、脆弱性修正の遅れや将来のABI変更に直接晒される（ヘッダがSDKに無い非公式扱いのリンケージ）。
  - Quick Look拡張の `.unsafeFlags` があり、パッケージ依存としては利用不可（直接ビルドのみ可）。
- **ビルド**: CLTツールチェーンで `swift build` 成功（49.7秒）。READMEも「Command Line Toolsのみで可、Xcode不要」と明記。

## 2. zip-porter（nlink-jp/zip-porter）

- **構成**: SwiftPMパッケージ。`ZipPorterCore`（UI非依存ZIPエンジン約3,700行）+ `ZipPorter`（AppKit GUI + 組み込みCLI）。macOS 14+ / Apple Silicon。
- **依存関係**: サードパーティSwiftパッケージ**ゼロ**。deflateはシステムzlib（`CZlib` shim）、inflateはCompressionフレームワーク。
- **機能（ZIP特化）**: NFC UTF-8 + UTF-8フラグによるWindows安全な作成、CP932切替（`--cp932`、表現不可文字はエラー）、CP932自動検出・手動指定・フォールバック付き復号、ZipCrypto/AES-256暗号化・復号、Deflate64復号、macOSジャンク除外、`.part` 一時ファイル→リネーム。
- **安全性**（`Unpacker.swift` を直接検証）:
  - Zip Slipガード: 絶対パス・`..`・Windowsドライブ文字・NTFS代替データストリーム(`:`)拒否、バックスラッシュも区切りに正規化
  - symlinkエントリは既定スキップ、既存ファイルへの上書きなし（O_EXCL排他作成 + NFC+case-fold衝突キーでユニーク名化）
  - 事前容量バジェット検査（overflow-safe）、キャンセル時は「自分が作ったものだけ」クリーンアップ
  - quarantine属性の継承と、継承失敗の報告
  - 敵対的フィクスチャ12種（truncated / size-lie / zip64 underflow / overlap / duplicate names等）によるテスト
- **ライセンス**: MIT。`CLAUDE.md`・ADR群（`docs/{en,ja}/adr/`）で設計判断が文書化されており、参照価値が高い。
- **リスク**: ZIPのみ（7z/RAR/tarはスコープ外と明言）。GUIはドロップレット型で、DIZUNが想定するFinder既定アプリ+内容プレビューUIとは異なる。単一開発組織のプロジェクト。
- **ビルド**: CLTツールチェーンで `swift build` 成功（30.5秒）。CLI `--version` 正常応答（`zip-porter dev`）。※`--help`は未実装でGUI起動を試みる（検証時は起動せず停止を確認）。

## 3. libarchive（libarchive/libarchive）

- **構成**: C言語ライブラリ。多形式（ZIP/7z/RAR5/tar/ISO等）対応の参照実装。
- **ライセンス**: 全体はBSD-2-Clause風だが**ファイル単位で例外**（UC Regents 3-clause、public domain、CC0/OpenSSL/Apache-2.0トリプルライセンスのBLAKE2、ビルドスクリプト類は個別確認要）。配布時は`COPYING`と各ファイル冒頭が正。
- **ビルド**: CLTのclang（`DEVELOPER_DIR`/`CC`明示）でcmake configure + `archive_static` ビルド成功（libarchive.a 約1.3MB、テスト・フロントエンド無効化構成）。
- **リスク**: コード規模が大きく、同梱運用は脆弱性追跡・ライセンス管理・プラットフォーム対応の恒常コストが発生する。形式追加フェーズまで同梱判断を先送りすべき。

## 4. 監査結論（要約）

1. **MVP（ZIP・日本語・Windows互換・安全）の要件に合致するのはzip-porterの設計**。純Swift・依存ゼロ・MIT・敵対的入力テスト済みで、DIZUNのコア課題（CP932/NFC/安全な解凍）を直接解く。
2. **crateは多形式対応のAppKitホスト参考資料として優秀**だが、エンジンがシステムlibarchive依存でバージョン制御不可、かつ日本語文字コード問題を解決しない。そのままの土台採用は不適。
3. **libarchiveは次フェーズ（7z/RAR読み取り）の候補**。同梱は pinned SHA + ライセンス監査 + サブセット検証を改めて行ってから判断。
4. いずれもテレメトリ・広告・外部通信のコードは確認されていない（Package.swift依存ゼロ・Cコードはlibarchive本体のみ）。

## 5. 帰属表記の方針

- DIZUN独自コードはMIT。zip-porter / crate から**コードを移植・複製する場合は**ファイル単位で出所SHAと著作権表示を保持し `THIRD_PARTY_NOTICES.md` に記録する。
- 仕様・設計のみ参考にした場合（発想・アルゴリズムの再実装を含む）も、監査文書での言及をもって出自を明示する。
- libarchive同梱時は `COPYING` 全文とファイル別ライセンス一覧の収録が必須。
