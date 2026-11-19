# DIZUN — Orca / Claude Code 初回キックオフ指示

あなたはDIZUN（ディズン）の主担当開発エージェントです。Orcaがオーケストレーションし、CodexはClaude Code単独では難しい技術課題や独立レビューが必要な場合だけ使います。

## 確定情報
- ローカル作業先: `/Volumes/Development/DevDog-Lab/dizun`（用意済み）
- GitHub: `https://github.com/DevDog-Lab/dizun.git`（ユーザーが作成済み）
- 正式名称: DIZUN（ディズン）
- ブランドの正本: `docs/DIZUN_BRAND_CONCEPT.md`
- 公開ソース方針: MIT。公開用サイトは `site/index.html`（まだ公開しない）

## 最優先ルール
1. まず既存リポジトリのファイル、`.git`、ブランチ、変更状態、remoteを検査し、絶対に既存データ・履歴を破壊・上書きしない。ZIP内のファイルと差分比較し安全に統合する。
2. **ローカルcommitは随時許可。push、PR、Pages公開、release、GitHubへの設定変更、remote writeは明示指示まで絶対禁止。** 承認を推測しない。
3. APIキー、トークン、パスワード、`.env`、秘密鍵、認証情報、個人データ、ログ、秘密を含むバイナリをGit・ドキュメント・サイト・履歴・公開ログに絶対含めない。値を画面に表示しない。
4. `.claude/skills/archive-repository-guard/SKILL.md` と `docs/PUBLICATION_POLICY.md` を常に適用。`git config core.hooksPath .githooks` を設定し、pre-commitガードと未承認push拒否を検証。`--no-verify` などの回避は禁止。
5. Finderの既定アプリ変更、既存のThe Unarchiver/WinArchiver Liteの削除、ユーザー環境の破壊的変更はしない。

## 最初のタスク（承認待ちで停止する必要はない範囲）
1. `CLAUDE.md`、ブランド正本、`docs/SPEC.md`、`docs/PUBLICATION_POLICY.md`、SKILL.md、README、サイトを読む。初回に差分・依存関係・構成を把握する。
2. Swift/Xcode/macOS環境を記録。Crate、zip-porter、libarchiveを監査し、ライセンス/依存関係/安全性/技術的適合性、固定SHAを `docs/OSS_AUDIT.md` にまとめる。OSSは検証前に採用確定しない。
3. 候補コードを別リサーチ領域で安全に調査・ビルドし `docs/BASELINE.md` に結果を記載。
4. Crate流用と新規SwiftUI/AppKitホストの比較を `docs/ARCHITECTURE_DECISION.md` に記録し、根拠のある構成を採用。
5. ZIPの最小圧縮/解凍、日本語ファイル名、内容SHA-256一致、上書き防止、Zip Slipなどのテストから実装を進める。完成前の機能をREADME/サイトで完成と称さない。
6. `docs/WORK_LOG.md` に変更、検証、未解決事項を記録し、検査のうえ意図したファイルのみローカルcommit。
7. 初回報告は「現状 / 監査結果 / 実装とテスト結果 / ローカルcommit SHA / 未解決事項 / 次の作業 / push未実施」を簡潔に。

この指示によって GitHub push や Pages 公開が承認されたと解釈しないこと。作業可能な範囲は自律的に進めてください。
