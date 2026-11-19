# DIZUN — 製品要件・初期技術設計 v0.3

作成日: 2026-11-19
状態: 技術選定案・実装前（ビルド、実機互換テストは未実施）
主担当: Claude Code／オーケストレーション: Orca／Codex: 難所発生時のみスポット利用

## 0. 確定したプロジェクト情報
- 名称: **DIZUN（ディズン）**。命名理由は `docs/DIZUN_BRAND_CONCEPT.md` を正とする。`unzip` の文字列全体を180度回転させる視覚的アイデアと圧縮・解凍の逆向きの操作を結びつけたブランド。
- GitHub: https://github.com/DevDog-Lab/dizun.git （ユーザーが作成済み。操作前にremote・既存内容を確認）
- ローカル: `/Volumes/Development/DevDog-Lab/dizun` （ユーザーが用意済み。上書きせず既存内容と統合）
- 公開方針: 公開MITリポジトリ。push、PR、Pages、releaseは都度明示承認が必要。
- ブランドのうちタグライン・ロゴ・アイコン・カラーは未決定。仮案を確定事項として扱わない。

## 1. 目的
Windows/macOS間のZIP受け渡しで起きる日本語ファイル名の文字化け、TXT/CSV本文の文字コード問題を減らす、完全ローカル動作のネイティブmacOS圧縮・解凍アプリを開発する。The Unarchiver / WinArchiver Liteを置き換える。広告・テレメトリ・アカウント・外部送信を実装しない。

## 2. 採用候補（採用は監査・検証後に確定）
- 第一候補・アプリ基盤: https://github.com/kleash/crate （MIT）。AppKit、libarchive、ZIP/7z/RAR/TAR等の閲覧/解凍、ZIP等の作成、Finder Services、Quick Look。既知の制限として暗号化7z/RARの解凍不可などがREADMEに記載。
- 日本語Windows互換の参考・移植元候補: https://github.com/nlink-jp/zip-porter （MIT）。NFC UTF-8/CP932 ZIP、ZIP暗号化、Deflate64解凍、安全対策、検証用CLI。
- 汎用解凍基盤: https://github.com/libarchive/libarchive （BSD系、ファイル単位のライセンスを確認）。macOS同梱版と自前同梱版の機能差に留意。

**OSSの各READMEの記載は機能の存在を示す一次情報だが、品質保証ではない。** 必ずコミット固定、LICENSEと第三者依存ライセンス確認、コードレビュー、テストを行う。コピーしたコードの著作権・ライセンス表記は保持する。

## 3. 製品体験
- Finderで.zipなどをダブルクリックすると既定アプリとして起動し、設定に応じ「即解凍」または「内容を開く」。最初の既定アプリ切替はユーザー操作で行う。
- Finderで選択したファイル/フォルダを右クリック → Services/Quick Actions →「このアプリで圧縮」。圧縮ファイルでは「ここに解凍」。初期版は確実に動くmacOS標準拡張方式を優先。
- ZIPの中身のファイル名・フォルダ構造を解凍前に表示。文字コードを自動検出し、UTF-8/CP932の手動切替と即時プレビューを用意。
- 進捗、キャンセル、上書き前確認、エラー詳細を表示。解凍完了後のFinder表示、元アーカイブをゴミ箱へ移動する設定を用意。自動削除はしない。

## 4. 互換性プロファイル
- 標準ZIP: UTF-8 filename flag、NFC正規化、Deflate/StoreなどWindows標準ツールに配慮した基本方式。zip64等の互換性は実機検証。
- 日本語レガシーZIP: CP932のファイル名、表現できない文字がある場合は無断置換せず停止・警告。
- 暗号化ZIP: AES-256とレガシーZipCryptoを別選択。ZipCryptoは弱い方式と明記。Windows標準の対応はOSバージョン別に実機確認。
- 高圧縮: 7z等。ただし相手がWindows標準機能のみで開けることは保証しない。
- macOS固有の不要ファイル（.DS_Store / __MACOSX / AppleDouble）を標準で除外。ただしユーザーが必要なメタデータを保持する選択肢を検討。

## 5. 文字化け対策
### ファイル名
- ZIP UTF-8 flagやUnicode Path extra fieldを優先評価。無指定・不整合ならUTF-8/CP932を候補に検証し、曖昧な場合はプレビューで確認できるようにする。
- バイト列に文字コード情報が存在しないケースでは100%自動判定できないことを仕様として明記する。
- 正規化は表示と書き込みで分けて扱い、元バイト列を必要な診断情報として保持する。

### ファイルの中身
- **通常解凍でファイル本文のバイト列を絶対に変更しない。** 解凍されたテキストファイルが文字化けするのは、閲覧アプリ側のデコード問題である場合もある。
- 別機能としてTXT/CSV等の文字コード判定・変換を提供。元ファイルを保存したまま、変換候補をプレビューしてからUTF-8版を書き出す。自動一括上書きしない。
- バイナリ、Office文書、画像などへの変換適用を防ぐ。

## 6. セキュリティとプライバシー
- テレメトリ、広告SDK、更新チェック通信、クラウド、外部APIを含めない。外部通信ゼロをテストとコード監査で確認。
- Zip Slip対策（../、絶対パス、ドライブ文字、特殊パス）、symlink/hardlink経由の脱出防止。
- zip bomb対策としてサイズ・ファイル数・階層・膨張比・ディスク容量を制限し、処理途中も監視。
- 壊れたアーカイブ、重複した名前、大文字小文字差、Unicode正規化の衝突を安全に処理。
- デフォルトで既存ファイルは上書きしない。中途半端な出力は一時領域から原子的に確定、キャンセル時はクリーンアップ。
- アーカイブのcom.apple.quarantineを抽出物へ適切に継承。実行権限・拡張属性の扱いを検証。
- パスワードをコマンドライン引数、ログ、解析レポートに含めない。

## 7. MVP（最初の完成条件）
1. .zipダブルクリックでアプリ起動・解凍。Finderの「このアプリケーションで開く → すべてを変更」が機能する。
2. Finder右クリックServices/Quick Actionsから複数ファイル/フォルダをZIP化。
3. 日本語ZIP作成の標準UTF-8/NFCと、互換用CP932切替。
4. 日本語ZIP解凍時の文字コード自動判定・手動指定・プレビュー。
5. 安全な通常解凍（内容のバイト列を変えない）、上書き事故防止、進捗/キャンセル。
6. ZIP圧縮のWindows Explorer互換テストと、Windows作成ZIPのMac解凍テスト。
7. 一切の外部通信なし・広告なしを確認。

## 8. 次フェーズ
- 7z/RAR/TARの対象別対応、暗号化7z/RARとDeflate64の実装・同梱ライブラリ検討。
- Quick Look、圧縮内の単一ファイル抽出、TXT/CSV文字コード変換、分割アーカイブ。
- 配布用署名、公証、Universal Binary、CI。

## 9. テストマトリクス
- OS: macOS（開発機の現行版）と入手可能なWindows 10/11のExplorer。OSバージョンを記録。
- 名前: ASCII、漢字、ひらがな、カタカナ、濁点/結合文字、絵文字、長いパス、CP932非表現文字。
- 形式: UTF-8 ZIP、CP932 ZIP、flag不整合、ZIP64、Deflate64、暗号化、複数階層、大容量、分割、破損。
- データ整合性: 抽出前後のSHA-256とファイルサイズ一致、本文非改変。
- 安全性: Zip Slip、symlink、zip bomb、重複パス、同名衝突、キャンセル、空き容量不足。
- UX: Finderダブルクリック、右クリック、既定アプリ設定、ドラッグ&ドロップ、エラー表示。

## 10. Claude Codeへの最初の実装タスク（Orca経由）
以下の順に進める。作業マシンの既存プロジェクトへ勝手に書き込まないこと。

1. OrcaからClaude Codeを起動し、作業ルートを確認。指定済みの `/Volumes/Development/DevDog-Lab/dizun` を確認し、既存状態を保存したうえで作業する。Crateとzip-porterを別々に取得（コミットSHAを記録）。
2. LICENSE、依存ライブラリ、必要な著作権表示、ビルド方法、セキュリティ上の懸念を監査して `docs/OSS_AUDIT.md` を作成。
3. それぞれを変更なしでビルド/テストし、結果を `docs/BASELINE.md` に残す。失敗は理由と環境を記録し隠さない。
4. Crateを土台にする案と新規SwiftUI/AppKitホストを作る案を、コード再利用・Finder連携・日本語ZIP・安全性・保守コストで比較し、`docs/ARCHITECTURE_DECISION.md` に記録。
5. MVPのコード構成、追加/変更対象ファイル、テストfixturesの作成計画を策定。監査・ベースラインを先に完了したうえで、ビルドとテストが通る最小のローカル実装まで進める。
6. 既存アプリをアンインストール・設定変更しない。必要なコマンドと検証手順を具体的に提示。
7. ローカルcommitは可。ただしGitHubへのpushや公開、配布はユーザーの明示指示を待つ。

## 11. 参考URL
- https://github.com/kleash/crate
- https://github.com/nlink-jp/zip-porter
- https://github.com/libarchive/libarchive
- https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes
- https://developer.apple.com/documentation/appkit/app-extensions

## 12. Orca / Claude Code / Codex 作業規約
- **Orca**: セッションのオーケストレーション、作業段階の管理、必要時のCodex呼び出し。ツール操作可否は実際の環境で確認する。
- **Claude Code（主担当）**: 調査、OSS監査、設計、実装、テスト、ドキュメント更新、ローカルcommitを一貫して実施。
- **Codex（例外）**: Claude Codeが解決不能なビルド不具合、アーカイブ安全性、文字コード判定の設計論点、ライセンス・アーキテクチャ上の独立レビューが必要な場合のみ起動。恒常的な並列開発には使わない。
- Codexへ渡すときは再現手順、関連ファイル、期待/実際の結果、ログ、試した手段、具体的な問いをまとめ、回答をClaude Codeが検証して取り込む。
- **GitHubへのpush・リモートリポジトリの新規作成・PR作成・公開・配布は、ユーザーの明示指示があるまで禁止。** ローカルcommit可。
- 既存の解凍アプリ、Finderの既定の関連付け、OS設定を勝手に変更しない。
- 外部リポジトリのcloneおよび依存解決時の通信は開発作業として許容するが、製品ランタイムでは外部通信ゼロを要求する。
- OSSの機能・ライセンスはREADMEだけで確定しない。実際のLICENSE、ソース、第三者依存を確認し、使えない場合は採用しない。
- 実装の各区切りで `docs/WORK_LOG.md` に実施内容、コミット、テスト結果、未解決事項、次の一手を残す。

## 13. 最初の完了ゲート
**ゲートA — 監査・判断:** `OSS_AUDIT.md`、`BASELINE.md`、`ARCHITECTURE_DECISION.md` を作成し、Crateを基盤に採用するかどうかを実証してから決める。

**ゲートB — 最小機能:** ZIP圧縮・解凍、ファイル本文のSHA-256一致、日本語ファイル名fixtures、既存ファイルの上書き防止の自動テストを通す。

**ゲートC — Finder連携:** 開発用アプリをユーザー操作で関連付けできること、右クリックサービスが表示・動作することを実機確認する。既定アプリの自動変更は禁止。

**ゲートD — Windows実機相互検証:** Explorerとの双方向ZIPテストを通してから互換性をうたう。環境未確保なら未検証と明記する。
