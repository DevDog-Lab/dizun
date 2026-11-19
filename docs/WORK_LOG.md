# WORK_LOG — DIZUN作業記録

## 2026-11-19 — 第1回: 監査・アーキテクチャ決定・ZIPコア実装（ゲートA達成、ゲートB機能達成）

担当: Claude Code（Orcaオーケストレーション）。Codex未使用（該当難所なし）。

### 1. 環境と制約

| 項目 | 状況 |
| --- | --- |
| macOS 27.2.1 (26B131), arm64 | 問題なし |
| Xcode 27.2 (27B52) | **ライセンス未同意**。`sudo xcodebuild -license accept` の実行待ち（ユーザー操作） |
| CLT Swift 6.3.3 | `DEVELOPER_DIR=/Library/Developer/CommandLineTools` でビルド検証に使用 |
| XCTest / swift-testing | CLTにモジュール無し → `swift test` 不可。**`dizun selftest` CLI（同一シナリオ）で代替検証** |
| gitleaks | 未導入（brewがXcodeライセンスエラーで失敗）。**push承認前に公式バイナリで導入が必須** |
| cmake 4.4.4 | 導入済み（libarchive検証に使用） |

### 2. 実施内容

1. **リポジトリ統合**: ローカルリポジトリはコミット0回・統合パッケージ展開済みの状態。競合・破壊なしを確認し初回コミット `f794f0c`。
2. **安全ガード有効化**: `git config core.hooksPath .githooks`。pre-commit（repo_guard staged）作動確認、pre-push が承認変数なしを拒否することを確認（push自体は未実施・禁止どおり）。
3. **OSS監査** (`docs/OSS_AUDIT.md`): crate / zip-porter / libarchive をSHA固定でcloneし、ライセンス・依存・安全性・日本語対応を実装レベルで確認。
4. **ベースライン** (`docs/BASELINE.md`): 3リポジトリとも変更なしビルド成功（zip-porter 30.5s / crate 49.7s / libarchive static 1.3MB、CLTツールチェーン）。
5. **アーキテクチャ決定** (`docs/ARCHITECTURE_DECISION.md`): 新規SwiftPMパッケージ + 自前ZIPエンジン（DizunCore）。zip-porterを設計参照、crate流用は見送り、libarchive同梱は先送り。
6. **DIZUNCore実装** (`Sources/DizunCore/`): 約1,300行。
   - `ZipReader`: EOCD/ZIP64/中央ディレクトリ解析、UTF-8フラグ優先・CP932自動検出・手動指定、Info-ZIP Unicode Path extra、ローカルヘッダ十字検証（overlap攻撃対策）、CRC/サイズ検証、膨張比・総量・件数リミット、暗号化・未対応方式の明示的拒否
   - `ZipWriter`: NFC UTF-8 + UTF-8フラグ（既定）/ CP932切替（表現不可はエラー）、Store/Deflate、16MB超はストリーミング+CRC/サイズpatch-back（data descriptor無し）、ZIP64出力、排他作成
   - `Unpacker`: Zip Slipガード（絶対パス/`..`/ドライブ文字/`:`/バックスラッシュ）、symlinkスキップ、**上書き绝不**（O_EXCL + NFC+case-fold衝突キーでユニーク名化）、事前容量バジェット、キャンセル時の自己作成分クリーンアップ、quarantine継承、DOS時刻・権限設定
   - `Packer`: 再帰走査、macOSジャンク除外、`.part`一時ファイル→リネーム
   - `dizun` CLI: pack / unpack / list / selftest
7. **テスト** (`Sources/DizunFixtures/`, `Tests/`): バイトレベルZIPクラフタ（`ZipCraft`）+ 14シナリオ。XCTestラッパーも用意（ライセンス同意後に `swift test` で同一シナリオ実行）。

### 3. 検証結果

- **`dizun selftest`: 14/14 PASS**（debug・release両ビルド）
  roundTripJapanese / cp932Write / cp932ReadAutoDetect / overwritePrevention / collisions / zipSlip / symlinkSkipped / corruption（不良CRC・サイズ嘘・未対応方式・暗号化・切断・ローカルヘッダ偽装） / zipBombGuards（宣言総量・膨張比・正当データ通過） / cancellationCleanup / duplicateNames / emptyArchive / zip64Read / streamingLargeFile(17MB)
- **外部ツール相互検証**（手動実施・コマンドは下記）:
  - 自作ZIP → `unzip -t` 全エントリOK、`ditto -x -k` 展開結果が元とバイト一致（diff -r）
  - `ditto -c -k` で作成したZIP → DIZUNで展開、SHA-256一致（テキスト・バイナリ）。dittoはUTF-8フラグを付けないため**自動検出（UTF-8優先）が実データで有効確認**
  - 40MB（16MB超ストリーミング経路）→ `unzip -t` OK、SHA-256一致
- **外部検証が拾った不具合（修正済み・記録）**:
  1. CRC-32の初期値が0であった（正: 0xFFFFFFFF開始）→ 自己テストだけでは検出不能。unzip -t で発見し修正
  2. ストリーミング書き込みのCRCを圧縮後バイトで計算 → 修正
  3. ディレクトリエントリ名の末尾スラッシュ欠落 → 修正
  4. ZIP64 EOCD解析で「ディスク内エントリ数」u64の読み飛ばし → 修正

### 4. コミット

| SHA | 内容 |
| --- | --- |
| `f794f0c` | 初回コミット: スターターパッケージ（方針・仕様・安全ガード一式） |
| `781e475` | 監査: OSS_AUDIT / BASELINE / ARCHITECTURE_DECISION |
| （本コミット） | DIZUNCore実装・テスト・CLI + WORK_LOG / THIRD_PARTY_NOTICES更新 |

**push・PR・Pages・releaseはすべて未実施**（ユーザー明示指示待ち）。

### 5. 手動検証コマンド（再現手順）

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build
.build/debug/dizun selftest
.build/debug/dizun pack <src> -o out.zip [--cp932]
.build/debug/dizun list out.zip
.build/debug/dizun unpack out.zip [-o dir] [--encoding auto|utf8|cp932]
unzip -t out.zip   # 外部整合性
ditto -x -k out.zip /tmp/out  # 外部展開
```

### 6. 未解決事項・次の作業

1. **ユーザー操作待ち**: `sudo xcodebuild -license accept`（`swift test`・xcodebuild・brewが使用可能になる。実行後、XCTestスイートを走らせ同じ14シナリオを公式テストランナーで確認する）
2. gitleaks導入（push承認前の必須項目。Xcodeライセンス解除後 `brew install gitleaks` または公式バイナリ）
3. アーカイブ本体のストリーミングReader化（現在はメモリ読み込み・2GiB上限）
4. 解凍側のジャンクスキップ（現在 `__MACOSX` 等はpack側のみ除外。ditto製アーカイブを実測で確認済み）
5. 暗号化ZIP（AES-256 / ZipCrypto）、Deflate64（SPEC次フェーズ）
6. ZIP64**書き込み**経路の自動テスト化（読み取りはシナリオ済み。書き込みは4GiB超が必要なため手動検証とする）
7. Finder連携（ゲートC）: .app化、CFBundleDocumentTypes、Services
8. Windows Explorer実機相互試験（ゲートD）
9. `unzip -l` の表示がUTF-8フラグ付き日本語名で化ける（Info-ZIP unzipの表示仕様。ditto・Explorerは正常。ドキュメントで注記予定）
