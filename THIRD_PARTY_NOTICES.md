# Third-party notices

## Current status

このリポジトリには現時点で**第三者のコード・バイナリは含まれていない**。依存関係はAppleプラットフォームのフレームワーク（Foundation / Compression / CryptoKit・テストのみ）に限る。

## Design references（コード複製なし・出所明示）

DIZUNCore の設計は、監査済みの以下のOSSプロジェクトを**設計参照**としている（`docs/OSS_AUDIT.md` 参照）。参照に留まり、ソースコードの複製・移植は行っていない:

- **zip-porter** (MIT, Copyright (c) 2026 nlink-jp, SHA `98684892dd266f1ca18f01ede91e829efe369c39`)
  - UTF-8優先のファイル名文字コード検証順序（`EncodingDetector`）
  - CP932 = `CFStringEncodings.dosJapanese` とする扱い（`FileNameTransform`）
  - エントリパスのサニタイズ規則（絶対パス・`..`・ドライブ文字・`:`・バックスラッシュ区切り）（`Unpacker.sanitize`）
  - NFC + case-fold の衝突キーによるユニーク名化と敵対的フィクスチャによるテスト手法（`Unpacker`・`Tests/*/hostile-*.zip`）
- **Crate** (MIT, Copyright (c) 2026 Shubham, SHA `b2cb60120b5e1c581ff0cb51dabe4b6a2d63edca`)
  - Finder Services連携・Quick Look構成の参考（未実装フェーズの参考情報として監査記録に保持）
- **libarchive** (BSD-2-Clause系, SHA `432ab464725aa99c53de7572979bd9bbbf382ed1`)
  - 同梱なし。次フェーズの多形式対応検討時のみ再監査のうえ、`COPYING` とファイル別ライセンスを収録してから配布する。

## システムライブラリのリンク（ソース同梱なし）

- **zlib**（AppleがmacOS/SDKに同梱、zlib license © Jean-loup Gailly, Mark Adler）: PNG再圧縮のレベル制御のため `DizunImage` が `/usr/lib/libz.dylib` をリンク。ソースの複製・改変は行っておらず出自として記録。

## 今後のコード取り込み時の規則

上流からコードを複製・移植する場合、必ず:
1. ファイル単位で元の著作権表示・ライセンス条文を保持する
2. 出所リポジトリとコミットSHAをファイルヘッダと本書に記録する
3. 本プロジェクトのMITライセンスが上流の義務を消去しないことを確認する
