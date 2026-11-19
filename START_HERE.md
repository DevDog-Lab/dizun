# DIZUN スターター一式 — 導入手順

## パス
- GitHub: https://github.com/DevDog-Lab/dizun.git （ユーザーが作成済み）
- ローカル: `/Volumes/Development/DevDog-Lab/dizun`（ユーザーが用意済み）

## 最初の導入
1. ZIPをMacで展開。**`.git` はZIPに含まない**。
2. 既存の `/Volumes/Development/DevDog-Lab/dizun` のファイルと差分比較し、既存ファイル・未コミット変更を保護してから安全に統合。`cp -R` で無条件上書きしない。隠しファイル `.claude` / `.githooks` / `.gitignore` も対象。
3. OrcaでClaude Codeを作業ディレクトリに接続し `CLAUDE_CODE_FIRST_PROMPT.md` の内容を送る。
4. Claude Codeが `git config core.hooksPath .githooks` を設定・検証して作業開始。
5. GitHubへのpush、Pages公開、PR、releaseは**別途明示指示**まで実施しない。

## 構成
- `CLAUDE.md` — 常時参照ルール
- `.claude/skills/archive-repository-guard/SKILL.md` — 専用安全スキル
- `docs/DIZUN_BRAND_CONCEPT.md` — ブランドの正本（添付原文）
- `docs/SPEC.md` — プロダクト要件と段階的開発計画
- `docs/PUBLICATION_POLICY.md` — 公開安全基準
- `README.md` / `site/index.html` — 公開文面・静的Webページ（未公開）
- `scripts/repo_guard.py` / `.githooks` / `.gitignore` — 安全対策
- `CLAUDE_CODE_FIRST_PROMPT.md` — 最初に送るプロンプト

## 注意
- `.env`や鍵を誤ってGitに含めないためのガードは**補助**であり、すべての秘密情報を検出する保証はない。push時はgitleaks履歴監査と人手レビューが必要。
- ZIPは開発準備一式。アプリ本体やビルド可能なXcodeプロジェクトはまだ含まない。
- OSSライセンスとブランド商標は未監査。
