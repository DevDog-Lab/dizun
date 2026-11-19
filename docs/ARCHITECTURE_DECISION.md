# アーキテクチャ決定 — v1.0

決定日: 2026-11-19
根拠: `docs/OSS_AUDIT.md`（監査）・`docs/BASELINE.md`（ビルド検証）
決定者: Claude Code（SPEC v0.3 ゲートAの枠組みに従う。ユーザー確認は次回報告時に求める）

## 決定

**DIZUNは新規Swiftパッケージとして開発する。crateを土台に流用しない。ZIPエンジン（DIZUNCore）は自前実装とし、zip-porter（MIT）を実装の参照・必要時の移植元とする。libarchiveの同梱は次フェーズ（7z/RAR対応）に先送りする。**

```
Dizun/                     SwiftPMルートパッケージ
├─ Sources/DizunCore/      UI非依存のZIPエンジン（Reader/Writer/安全性/文字コード）
│   └─ Tests/DizunCoreTests/   敵対的フィクスチャを含むユニットテスト
└─ （後日）Sources/DizunApp/  AppKit/SwiftUIホスト、Finder連携、Quick Look
```

## 比較

| 観点 | A: crate流用 | B: zip-porterコア移植 | **C: 自前エンジン（採用）** |
| --- | --- | --- | --- |
| 日本語CP932検出・変換 | 無し（libarchive既定に依存） | 完備 | 自前実装（参照あり） |
| エンジンのバージョン制御 | 不可（macOS同梱libarchive） | 可 | 完全可 |
| 依存関係 | システムlibarchive（非公式ヘッダ） | システムzlib + Compression | **Compressionフレームワークのみ** |
| 多形式対応の将来 | 即時可得 | ZIPのみ | ZIP後、libarchive同梱で追加 |
| コード量の初期負債 | 約1,000行の理解 + 乗り換え | 約3,700行の取り込み | 0から（MVP部分は約1,500行見込み） |
| ライセンス帰属 | MIT表示要保持 | MIT表示要保持 | 設計参照の明示のみで開始可 |
| テスト資産 | crateのTestsあり | 敵対的FIxture 12種あり | 自作fixtures（SPEC §9マトリクス準拠） |

## 根拠（監査で確認した事実のみ）

1. **crateはDIZUNの中核課題を解かない。** `grep` によりCP932/Shift_JIS検出のコードは存在せず、作成時 `zip:hdrcharset=UTF-8` の指定のみ（`Write.swift:111`）。エンジンはmacOS同梱libarchiveでバージョン制御不可（監査§1）。
2. **zip-porterはzip特化で設計思想がDIZUNと一致**するが、`Package.swift` にproducts宣言が無くSwiftPM依存として利用できない。全コア（約3,700行）のvendoringは、独自UX（解凍前プレビュー・文字コード手動切替）を持つDIZUNでは上流からの分岐管理コストが利益を上回る。ただし `Unpacker.swift` の安全設計（Zip Slip、NFC+case-fold衝突、事前容量検査、O_EXCL、quarantine継承）と `EncodingDetector.swift` のUTF-8優先検証順序は**設計参照として採用**する。
3. **libarchive同梱は現時点で不要。** MVPはZIPのみ（SPEC §7）。多形式は次フェーズでpinned SHA・ライセンス一覧・サブセット検証を条件に再判断（監査§3のリスク記録のとおり）。
4. **CompressionフレームワークでDEFLATEが完結**するため、MVP時点でC依存ゼロを実現できる（`COMPRESSION_ZLIB` はraw DEFLATE）。deflateの出力決定性を重視する場合はzip-porter ADR-0003（システムzlib採用）を再検討する。

## MVPスコープ（初期実装の範囲）

含める: ZIP読み込み（EOCD/中央ディレクトリ、UTF-8フラグ、CP932自動検出・手動指定、Store/Deflate）、書き込み（NFC UTF-8 + UTF-8フラグ、CP932切替、Store/Deflate、CRC-32）、安全性（Zip Slip、絶対パス・ドライブ文字・`:`拒否、symlinkスキップ、上書き禁止・ユニーク名化、NFC衝突判定、事前容量検査、膨張比・総量上限）、ZIP64読み取り（必須タイミングで）。

含めない（次フェーズ以降）: 暗号化（AES/ZipCrypto）、Deflate64、7z/RAR/tar、Finder連携、Quick Look、TXT/CSV本文変換。

## リスクと保全

- 自前エンジンの品質リスク → 敵対的フィクスチャ（zip-porter方式を参考に自作）とWindows Explorer実機相互試験（SPECゲートD）で対処する。
- zip-porter設計の取り込みは「設計参照」として本文書とコードコメントに出所を明示。**コードを複製した場合は**ファイル単位の帰属表記を `THIRD_PARTY_NOTICES.md` に追加する。
- この決定はSPECゲートA（監査・判断）の成果物であり、ユーザーのレビュー・差し戻しを受け付ける。
