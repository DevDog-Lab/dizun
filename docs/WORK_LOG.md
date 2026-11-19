# WORK_LOG — DIZUN作業記録

## 2026-11-19 — 第18回: 画像最適化設定行のレイアウト修正

- ユーザー報告: 長辺欄が広すぎる／KB欄がまだ表示されない。
- 原因: 1行に全要素を並べた合計幅が窓幅を超え、**末尾の目標欄が水平方向にクリップ**されていた（高さではなく幅の問題だった）。
- 対応: 数値欄を52px（5桁分）に縮小、ゴミ箱チェックボックスを別行に分離、窓幅を内容に応じ最小520pxへ自動拡大。
- 検証: 警告0・25/25・インストール済み。表示はユーザー確認待ち。
- コミット: （本コミット）


## 2026-11-19 — 第17回: ドロップレット窓の画像最適化行の表示と入力改善

- ユーザー報告（スクリーンショット付き）: 目標KB入力欄が見えない／px単位が欲しい／半角数字のみにしたい。
- 原因: 窓の高さが300px固定で、追加された行が内容に収まらず下段（目標欄）がクリップされていた。
- 対応:
  1. 窓サイズを内容のfittingSizeから自動算出（固定高を廃止）
  2. 「長辺 [欄] px 目標 [欄] KB以下」の単位付き表示
  3. 数値欄は入力をリアルタイム検査: 全角数字（IME）→半角へ自動変換、数字以外は除去、上限5桁。結果として半角数字のみの入力になる（macOSのNSTextFieldにiOS式キーボード種別指定は無いため、変換方式で実現）
  4. 入力のたびに設定へ即時反映
- 検証: ビルド警告0・25/25テスト・/Applicationsへインストール。レイアウトはユーザー確認待ち。
- コミット: （本コミット）


## 2026-11-19 — 第16回: 画像最適化のデータ損失バグ修正とカスタム入力対応

- ユーザー報告（重大）: リサイズ1280/1920で「圧縮版がゴミ箱へ移動し元ファイルが消滅」、リサイズなし/2560は無反応。
- **根因**: `NSWorkspace.recycle` が非同期。engineが`removeItem(url)`で元を削除→`moveItem`で最適化版を配置した**後**にrecycleが実行され、パス上のファイル（＝最適化版）をゴミ箱へ動かしていた。元は削除済みのため消失。
- **修正**:
  1. engine置換を**ロールバック可能な駐車順序**に変更（元を`.old`へ退避→新規配置→成功後のみ退避分削除、失敗時は元へ復元）。元の`removeItem`先行削除を廃止
  2. アプリのバックアップを**同期の~/.Trashへのmove**に変更（NSWorkspace.recycle不使用。同一ボリュームrename。Finderの「戻す」情報は付かない旨を注記）
  3. 縮小0件時に「縮小できませんでした」情報ダイアログを表示（無反応に見える問題の解消。リサイズなし/2560は多くの場合すでに最適化済みで正当スキップだった）
- **追加要望対応**: 長辺pxの自由入力（任意値・空欄でなし）、JPEGの**目標サイズ（KB以下）**設定（品質を0.8→0.3まで段階的に下げて目標達成を探索、未達時は最小の結果を採用し増大はしない）。ドロップレット窓をテキスト入力2つに変更。
- 検証: XCTest/selftest **25/25**（目標サイズ達成・未達時非増大・カスタム長辺1111pxの3シナリオ追加）。実機スモーク: 最適化版47,189バイトが元場所に、元50,206バイトがゴミ箱に確認。
- コミット: （本コミット）


## 2026-11-19 — 第15回: 画像最適化機能（フェーズ1）の実装

- 提案書（第14回検討）へのユーザー承認: 実装GO・元画像はゴミ箱へ（設定可）・EXIF全削除・WEB用リサイズ許可。
- **DizunImage新ターゲット**（Appleフレームワーク＋システムzlibのみ、外部コードゼロ）:
  - PNG: チャンク解析→テキスト/EXIF系チャンク削除（色関連は保持）→IDATをzlibレベル9で再圧縮（スキャンラインはバイト完全一致）。zlibラッパーは`CZlib` shim経由
  - JPEG: セグメント解析→EXIF/XMP/IPTC/COM削除、SOS以降のスキャンデータは逐語コピー（画素ビット完全一致）。orientation非恒等は事前に画素へ焼込（メタ削除で縦横が崩れないように）
  - リサイズ: 長辺上限（ImageIO thumbnail、orientation焼込兼用）。ImageIOが再エンコード時に書く独自EXIFは必ずストリップ
  - 安全策: 厳格に小さくなる場合のみ置換、一時ファイル→検証→アトミック置換、backupクロージャ（アプリ層でゴミ箱移動）
- **統合**: 画像のみのドロップ→最適化（それ以外は従来どおりZIP）、サービス「DIZUNで画像を最適化」(public.image)、ドロップレット窓にリサイズ選択（なし/1280/1920/2560）と「元画像をゴミ箱へ」、CLI `dizun optimize [--max-dimension]`
- **検証**: XCTest/selftest **23/23**（画像シナリオ6件: PNG損失なし・JPEGメタ削除とスキャン同一性・orientation焼込・リサイズ・バックアップ・非拡大時非破壊）。実測: sips製PNG 57.6%減、3000pxノイズ画像1280px化71%減
- テスト過程で発見・修正: PNGチャンク長仕様（データ部のみ）、グラデ画像で再エンコードが増大するケースの正当拒否、ImageIO再エンコード時のEXIF混入
- コミット: （本コミット）


## 2026-11-19 — 第14回: 暗号化圧縮の二重ZIP化（構成隠蔽）と自動アンラップ

- ユーザー判断: 「暗号化の場合は二重Zipにしよう」— ZIP書式上ファイル名・構成は平文で見えるため、暗号化時は必ず二重ZIP化する仕様を採用。
- **Packer**: 暗号化指定時は内側（平文・実構成）→外側（暗号化・エントリ1個・`DIZUN-NESTED-1`コメント）の二段構成。Resultは内側の実カウントを報告。
- **Unpacker**: コメントマーカー+エントリ1個+拡張子.zipの3条件で**自動アンラップ**（内側を展開し中間zipを削除、quarantineは外側由来を再適用、カウント・top itemsを実構成に差し替え）。一般の「たまたまzipを含むアーカイブ」は触らない。
- **ZipWriter/ZipReader**: アーカイブコメントの読み書きに対応（EOCDコメント欄）。
- CLI `pack --password` も自動的に二重化。`list`/プレビューは外側1エントリのみ表示（＝名前が見えないことが仕様どおり可視化される）。
- 検証:
  - シナリオ更新（AES/ZipCrypto両方が二重前提に）+ selftest/XCTest **17/17**
  - **7-Zip交叉**: パスワードなし `7zz l` では「機密袋.zip」1件のみ表示（実構成は完全に隠蔽）。パスワード付きテスト合格→抽出→内側を通常解凍で内容完全一致
- コミット: （本コミット）

## 2026-11-19 — 第13回: 圧縮サービスを暗号化あり/なしで分離

- ユーザー報告: 右クリック→サービスの圧縮で、ドロップレット窓で選んだ暗号化設定が共有されており毎回パスワードを求められる。
- 対応: Servicesに**「DIZUNで圧縮」（暗号化なし・固定）**と**「DIZUNで圧縮（暗号化）」（AES-256・都度パスワード入力）**の2種類を用意。サービス経由は永続設定（Settings.compressEncryptionKind）を参照しない。ドロップレット/ Dockドロップ経路は従来どおり永続設定を使う。
- 実装: `WorkCoordinator.CompressMode`（fromSettings/plain/encrypted）、`compressEncryptedService`ハンドラ追加、Info.plistのNSServicesを更新。
- 検証: ビルド警告0・17/17テスト・/Applicationsへインストール・pbsに3サービス登録を確認。
- コミット: （本コミット）

## 2026-11-19 — 第12回: アプリアイコン採用とプレビューボタン無効の修正

- ユーザー報告2件へ対応:
  1. **プレビューウィンドウの解凍/キャンセルボタンが無効**（コミット `1d18196`）: ウィンドウはコントローラを保持しないため表示直後にコントローラが解放され、ボタン・テーブルのtargetが消えていた。AppDelegateが強参照配列で保持し`windowWillClose`で解除。
  2. **ユーザー提供画像をアプリアイコンに採用**（本コミット）:
     - `Assets/icon-source.png`（2000×2000 PNG・ユーザー作成・2026-11-19提供）→ 1024px正規化 → iconset全サイズ → `Assets/AppIcon.icns`
     - Info.plistに`CFBundleIconFile`、build-app.shがResourcesへ格納。`/Applications/DIZUN.app`へ適用済み
     - **ブランド上の位置づけ**: `DIZUN_BRAND_CONCEPT.md`はロゴ/アイコン「未決定」としていたが、ユーザーが明示的に本画像を提供・指定したため**アプリアイコンとして承認扱い**（正規ロゴタイプ・タグラインは引き続き未確定）
     - repo_guard.pyに`Assets/*.png|icns`の限定許可を追加（目視検査済みの画像資産のみ。他のバイナリは従来どおりブロック）
- スモーク: `/Applications/DIZUN.app`でプレビュー表示・存続・終了を確認。ボタン操作はユーザー確認待ち。

## 2026-11-19 — 第11回: /Applicationsへの自動インストール導入

- ユーザー要件: 既定アプリ設定に備え、ビルドのたびに最新アプリをアプリケーションフォルダへ配置したい。
- `scripts/build-app.sh` が既定で `/Applications/DIZUN.app` へインストールするよう変更（`DIZUN_NO_INSTALL=1` でスキップ可）:
  - 実行中のDIZUNをgraceful quitしてから置換（動作中はインストール中止を報告）
  - インストール側を `lsregister -f`、ビルドパス側を `lsregister -u` で登録解除 →「このアプリケーションで開く」にDIZUNが1つだけ表示される状態を維持
- 導入直後の登録状態を確認: `/Applications/DIZUN.app` のみ登録済み。
- **既定ハンドラの切替自体はユーザー手操作のまま**（ガードレール: アプリ・スクリプトからFinder既定を変更しない）。
- 以後のスモークテストも `/Applications/DIZUN.app` を使う（build/パスの再登録を避ける）。
- コミット: （本コミット）

## 2026-11-19 — 第10回: パスワード付きZIP圧縮・解凍（AES-256 / ZipCrypto）

ユーザー要件「圧縮時にパスワードを設定」に対し、SPEC §4どおりAES-256（既定・推奨）とZipCrypto（旧互換・脆弱）の選択制で実装。

- **エンジン**（コミット `957c626`）:
  - `WinZipAES`: PBKDF2-HMAC-SHA1(1000回)・AES-CTR(WinZip式LEカウンタ)・HMAC-SHA1認証タグ。鍵導出バッファの消去。検証子(2byte)+HMACによる誤パスワード検出
  - `ZipCryptoCipher`: PKWARE伝統型。チェックバイトはCRC上位（data descriptor時はDOS時刻上位へフォールバック）
  - Writer: 方式99+0x9901 extra（両ヘッダ）、ストリーミング経路の暗号化、ZipCryptoのCRC事前計算パス、版数51
  - Reader: 両方式復号、`passwordRequired`/`wrongPassword`の分離、AE-2はCRC省略(HMACで保証)
  - Unpacker: パスワード無しを**ディスクtouch前**に拒否（リトライ時に残骸を出さない）
  - 膨張比上限200→1000へ緩和: 逆方向交叉検証で225:1の正当な高圧縮ファイルの誤拒否を発見。DEFLAVE理論上限≈1032:1に合わせ、絶対容量キャップが爆弾対策の主体
- **交叉検証（7-Zip 26.00 / Info-ZIP unzip）双方向**:
  - DIZUN作成AES-256/ZipCrypto ZIP → 7zz・unzipがパスワード付きで完全復号・SHA-256一致
  - 7zz作成AES-256/ZipCrypto ZIP → DIZUNが完全復号・SHA-256一致
- **CLI**: `pack --password [--zipcrypto]`（二重入力・エコーOFF。パスワードはargv/ログに出さない）、`unpack` はパスワード必須時に自動プロンプト
- **アプリUI**（本コミット）: ドロップレット窓に暗号化方式選択（なし/AES-256/ZipCrypto=弱い明記・永続化）、圧縮時にパスワード二重入力プロンプト（保存されない）、解凍時は保護アーカイブを検出したら事前プロンプト、プレビューの警告文更新
- 検証: XCTest/selftest 17/17（暗号化シナリオ2件追加）、警告0ビルド
- **未検証**: アプリUIのパスワードプロンプト実機操作（ユーザー確認待ち）。Windows実機での暗号化ZIP開封（ゲートD。Windows 11 ExplorerはAES対応済みという報告があるが未確認）

## 2026-11-19 — 第9回: Windows互換性のMac側多面的検証（ゲートD前の信頼性評価）

Windows実機検証（ゲートD）は当面不可のため、Mac上で可能な独立実装による交叉検証を実施。

| 検証 | 実装 | 結果 |
| --- | --- | --- |
| UTF-8 ZIPの構造・CRC | Info-ZIP unzip -t | 全エントリOK |
| UTF-8 ZIPの構造・フラグ・版数 | python zipfile | 完読・CRC合格。flag 0x0800は非ASCII名のみ、ver 2.0、store/deflate、Unix、zip64なし — 意図どおり |
| CP932 ZIPの名前バイト | python zipfile | flag無し・生バイトがCP932として正しく復号 |
| UTF-8 ZIPの表示・整合 | **7-Zip 26.00（7zz）** | テストOK、**日本語名が完全に正しく表示** |
| CP932 ZIP・MS拡張文字ZIPの整合 | 7-Zip | 両方テストOK |
| CP932 MS拡張文字（㈱①Ⅲ№～）の復号 | python/zlibでバイト級クラフト→DIZUN | 自動検出cp932・全名正復号・抽出OK |
| 生成・展開の双方向 | ditto | バイト一致（第1回〜継続） |

- 7-Zip on MacがCP932 ZIPの展開に失敗（errno=92）するのは**Mac側ロケール制約**（非UTF-8バイトのファイル名を作れない）。日本語ロケールのWindowsではCP932がシステム既定のため動作する系統。CP932モードの前提「日本語環境の受信者」を文書化する根拠。
- 評価のまとめは会話ログおよび本エントリのとおり。**公称（README・サイト）はゲートD通過まで「Windows実機未検証」を維持**。
- コミット: （本コミット）

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
