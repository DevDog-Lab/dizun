# Third-party notices

## Current status

DIZUNCore（ZIPエンジン）とDizunImage（画像最適化）は第三者コードを含まない。**多形式対応（tar・7z・RAR受信・LZH受信）のために、ビルド成果物として libarchive と liblzma を同梱する**（下記「Vendored binaries」）。ソースコードの複製は行わない。

## Vendored binaries（多形式エンジン・静的リンク）

ビルド成果物（`vendor/*.xcframework`）はGit管理外。`scripts/vendor/build-vendor.sh` が監査済みの固定リビジョンから再生成する。`vendor/manifest.txt` に取得物のSHA-256を記録する。

```text
Component: libarchive
Upstream: https://github.com/libarchive/libarchive
Revision: 432ab464725aa99c53de7572979bd9bbbf382ed1 (2026-11-16監査)
Integration: static (archive_static), arm64, macOS 14.0, scripts/vendor/build-vendor.sh
Linked subset: tar / 7zip / rar / rar5 / lha readers+writers via列挙登録, zlib+bzip2+liblzma のみ有効
  (LIBB2/LZ4/ZSTD/LZO/OpenSSL/mbedTLS/Nettle/XML/PCRE はOFF。/opt/homebrew 参照をCMakeCacheで拒否)
Licenses: COPYING — 全体はBSD-2-Clause風だがファイル単位で例外:
  - libarchive/* の大部分: BSD-2-Clause系
  - compress reader/writer, mtree.5: UC Regents 3-clause BSD
  - archive_parse_date.c 等: public domain
  - BLAKE2 (blake2sp*): CC0 / OpenSSL / Apache-2.0 のトリプルライセンス → CC0を選択
Dependencies: Apple SDK の libz.tbd / libbz2.tbd、下記 liblzma
Verified: 上流テスト・交叉検証は docs/WORK_LOG.md の該当回に記録
```

```text
Component: liblzma (XZ Utils)
Upstream: https://github.com/tukaani-project/xz
Revision: v5.8.4 d3e650e63c110e830fd5391e7f8b45df0b91d3da
Integration: static (liblzma.a), arm64, macOS 14.0, scripts/vendor/build-vendor.sh
Linked subset: liblzma ライブラリのみ（CLI・スクリプト類はビルドしない）
Licenses: liblzma は BSD Zero Clause License (0BSD) — COPYING.0BSD
  （同梱するのは liblzma のみであり、GPL/LGPL系ファイルは含まない）
Dependencies: なし（Apple SDK のみ）
Verified: libarchive 交叉検証時に合同で確認（docs/WORK_LOG.md 記録）
```

配布時は About 画面・リソースから本書を開けるようにする。BLAKE2のライセンス選択（CC0）は採用ファイル冒頭と再照合のうえ確定する。

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
