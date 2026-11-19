# WORK_LOG — DIZUN作業記録

## 2026-11-19 — 第8回: 解凍前プレビュー・文字コード手動切替UI（MVP 3/4のUX面）

- **ArchivePreviewWindowController**: `.zip`オープン時に内容一覧（名前・サイズ）+ 文字コード選択（自動判定結果表示付き / UTF-8 / CP932、切替で即時再デコード）+ 解凍/キャンセル。未対応圧縮方式・暗号化項目の警告表示。破損アーカイブはエラー表示。
- **Settings（UserDefaults）**: `instantExtract`（既定false=プレビュー優先）、`compressEncoding`（UTF-8/CP932）。
- **ドロップレット窓**に圧縮文字コード選択（セグメント、即保存）。Services/Dockドロップの圧縮にも適用。
- ZipEntryに `isEncrypted` を公開追加（プレビュー警告用）。エンジンロジック無変更、15/15合格。
- スモーク: `open -a app test.zip` → 即解凍せずプレビュー表示・アプリ存続・osascript終了 ✓。
- ユーザー実機確認待ち: プレビュー表示、CP932切替の即時プレビュー、CP932圧縮（絵文字名のエラー含む）。
- コミット: （本コミット）

## 2026-11-19 — 第7回: ゲートC達成の確定（ユーザー実機確認）

- ユーザー実機確認により以下がすべて動作確認された:
  1. `.zip` オープンでの解凍（オープン経由）
  2. Finder右クリックサービス（DIZUNで圧縮／DIZUNで解凍）の表示・動作
  3. Dockアイコンへのドラッグ&ドロップ（実行中・未起動ピン留め両方、ZIP圧縮・解凍両方）
- **SPEC §13 ゲートC（Finder連携）を達成・確定**。既定アプリの変更はユーザー操作のみで実施（アプリ側からの主張なし）。
- ローカルコミット計9件（push未実施）。
- MVP（SPEC §7）の残: 3/4のUI面（圧縮時CP932切替・解凍時文字コード手動指定/プレビュー）、6（Windows実機相互試験=ゲートD）。

## 2026-11-19 — 第6回: 未起動Dockピン留めアイコンがZIP以外のドロップを受けない問題の修正

- ユーザー報告: 手動テスト4（Dockピン留め・閉じた状態からのドロップ）が失敗。クラッシュレポート無し。
- 原因: **未起動のDockタイルは、アプリが宣言したUTIのみ受け付ける**（実行中タイルは無条件）。DIZUNは `public.zip-archive` しか宣言しておらず、フォルダ/通常ファイルのドロップはDockの段階で拒否されていた（テスト2・3は実行中だったため問題なし）。
- 対策: `CFBundleDocumentTypes` にKeka式のドロップレット宣言を追加（`public.item` + `public.folder`、Role=Viewer / Rank=Alternate — 通常ファイルの既定ハンドラも主張しない）。zip-porterも同様にZIPのみ宣言しており、Dockピンでの汎用ドロップは持たない設計。
- 再ビルド・`lsregister -f`・`pbs -update`。LS dumpで `claimed UTIs: public.zip-archive, public.item, com.pkware.zip-archive, public.folder` を確認。
- 注意: 開発中に `build/Dizun.app` を作り直すとDockピンの参照が無効化されることがある。再ピン留め（アイコンをDockから外し、新ビルドを起動してから「Dockに保持」）で復旧。
- コミット: （本コミット）

## 2026-11-19 — 第5回: Dockアイコンへのドラッグ&ドロップ対応

- ユーザー実機確認でゲートC達成を確認（右クリックサービス表示・動作）。追加要件としてDockアイコンのドロップ対応を実装。
- LSUIElementを廃止しregularポリシー化（Dockアイコンがドロップ先になる。Dockピン留めすれば常駐のランチャー兼ドロップ先）。
- ワンショット終了判定を修正: 従来の`NSApp.isActive`判定はregular化で常にtrueになり居座る原因だったため、「起動シーケンス完了フラグ + ドロップレット窓の有無」で判定:
  - 未起動（ピン留めDock/ダブルクリック）→ 処理後に自動終了
  - ドロップレット窓を開いている実行中 → 処理後も居座る（連続ドロップ可）
- 検証（`open -a`でDockドロップと同一のLaunchServices経路）:
  1. 未起動ドロップ → `資料 2/`抽出・内容一致・自動終了 ✓
  2. 実行中ドロップ → `資料 3/`抽出・既存を上書きしない・アプリ存続・手動終了 ✓
- コミット: （本コミット）。実際のDockドラッグ操作はユーザー確認待ち。

## 2026-11-19 — 第4回: 右クリックServicesが表示されない問題の修正

- ユーザー実機確認: .zipオープン解凍は動作（ゲートC前半達成）。右クリックサービスに出ない、`open`の相対パス指定ミス（ホームで実行）を報告受けた。
- 原因: Info.plistのサービス定義に旧式 `NSSendTypes=NSFilenamesPboardType` を使用していた。pbsには登録される（dumpで確認済み）が、現代のFinderは**選択対象へのUTI適合判定**でメニューを出すため、`NSSendFileTypes`（UTI）が無いと右クリックに出ない。監査済みのcrate実装（Resources/Crate-Info.plist）と同じ構成に修正:
  - DIZUNで圧縮: `NSSendFileTypes = public.item, public.folder` + `NSRequiredContext={}`
  - DIZUNで解凍: `NSSendFileTypes = public.zip-archive`
- 再ビルド→`lsregister -f`→`pbs -update`→pbs dumpでUTI版登録を確認→`open`で1度起動しosascriptで終了（LaunchServices経由起動を1回実行）。
- コミット: （本コミット）。ユーザーによる右クリック表示の再確認待ち。

## 2026-11-19 — 第3回: ゲートC（Finder連携）の実装とスモーク検証

- **DizunApp**（AppKitシェル、LSUIElement・アクセサリ動作）を実装:
  - `.zip`オープンで解凍（one-shot: 完了後に自動終了、Finder表示）
  - Finder右クリックServices: 「DIZUNで圧縮」「DIZUNで解凍」（NSServices / NSFilenamesPboardType）
  - 進捗パネル（キャンセル付き・スループット表示は今後）、ドロップウィンドウ（プレーン起動時）
  - ドロップ/オープン判定は共通: ZIPのみ→解凍、それ以外→圧縮（Finder流の命名・ユニーク化）
  - 圧縮先は1項目なら「名前.zip」、複数なら「Archive.zip」（上書きしない）
- **scripts/build-app.sh**: SwiftPMリリースビルドから `build/Dizun.app` を生成（Info.plist・PkgInfo・adhoc署名）。Xcodeプロジェクト不要。
- **Info.plist**: `CFBundleDocumentTypes` で ZIP を `LSHandlerRank=Alternate` で登録（**既定アプリの主張なし**。切り替えはユーザー操作のみ）。`LSUIElement=true`。
- **スモーク検証（自動）**:
  1. `DizunApp test.zip` → 既存`src`を上書きせず `src 2/` に展開、日本語ファイル内容完全一致、exit 0で自動終了
  2. `DizunApp ファイル.txt` → 元ファイルの横に `ファイル.zip` 生成（UTF-8フラグ付き）
  3. `lsregister -f build/Dizun.app` + `pbs -update` で登録（UIを出さず完了）。`claimed UTIs: public.zip-archive, com.pkware.zip-archive / rank: Alternate` を確認
- エンジン側は無変更。`swift test` 15/15・ビルド警告0を再確認。
- **ユーザー実機確認待ち（ゲートCの残り）**: Finder右クリック→サービスに「DIZUNで圧縮/解凍」が表示されるか、.zipの「このアプリケーションで開く」にDIZUNが出るか。既定変更（すべてを変更）はユーザーの意思でのみ。
- コミット: （本コミット）

## 2026-11-19 — 第2回: Xcodeライセンス解除後の公式テスト実行と解凍側ジャンクスキップ

- ユーザーが `sudo xcodebuild -license accept` を実行。Xcode 27.2ツールチェーン（Swift 6.4.2）が有効化。
- **`swift test`（XCTest公式ランナー）で第1回の14シナリオが全件合格**することを確認（selftest CLIとの同等性を実証）。
- **gitleaks 8.30.1導入**（Homebrew）。全履歴スキャン: 4コミット・漏洩なし。pushゲートの要件が揃った（push自体は未実施）。
- **解凍側ジャンクスキップ実装**: `JunkFilter`（pack/unpack共通）、`Unpacker.Options.skipMacJunk`（既定ON・結果に `skippedJunk` として報告、オプトアウト可）。SPEC §4の双方向対応を完了。
- シナリオ `unpackJunkSkipped` 追加。**XCTest・selftestとも15/15合格**。
- 実データ検証: `ditto -c -k` 製アーカイブ（`__MACOSX/` 3エントリ入り）でジャンクのみスキップされ、`圧縮テキスト.txt`・`data.bin` が正しく抽出されることを確認。
- コミット: （本コミット）

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
