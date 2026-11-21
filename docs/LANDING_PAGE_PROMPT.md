# DIZUN ランディングページ — 設計プロンプト

> この文書は、devdog-lab.com の DIZUN 製品ページ（`/ja/dizun/`・`/en/dizun/`）を
> devdog-lab-site リポジトリで実装する担当者に渡す設計プロンプトです。
> DIZUN リポジトリ側では実装しません。ファクトの正本は本リポジトリ（dizun）の
> `README.md`（2026-11-21版）と `docs/DIZUN_BRAND_CONCEPT.md` です。

---

## 依頼

devdog-lab.com に DIZUN の製品ランディングページ（日本語・英語の2言語）を作成してください。
実装は `/Volumes/Development/DevDog-Lab/devdog-lab-site/site`（Astro）で、既存の
Combox / Melo / Clatch / Honyac ページの構造・慣習に厳密に従います。

## 実装先の慣習（既存4製品から抽出・必ず踏襲すること）

- ページ: `src/pages/ja/dizun/index.astro` と `src/pages/en/dizun/index.astro` は薄いラッパーとし、
  `BaseLayout`（props: `title` / `description` / `lang` / `canonicalPath` / `ogImage`）+
  ランディング本体コンポーネント `src/components/dizun/DizunLanding.astro`（ja/en 共通・`lang` prop で分岐）で構成する。
- コピー（全文言）: `src/content/dizun.ts` に `ja` / `en` 両方を集約する。
  ファクトは dizun リポジトリの `README.md` と `docs/DIZUN_BRAND_CONCEPT.md` のみから引用し、
  ファイル頭に「事実は dizun/README.md・docs/DIZUN_BRAND_CONCEPT.md に準拠。未確定事項を宣伝しない」という
  出典コメントを付ける（既存 `content/clatch.ts` の書式を参考）。
- ブランドアセット: `public/brands/dizun/` にアイコン等を配置（後述のアセット節を参照）。
- OGP 画像: `public/og/dizun.png`（既存 `public/og/*.png` と同寸法・同作法）。
- トップページ登録: `src/content/ja.ts` / `en.ts` に `dizunCta`（`href: '/ja/dizun/'`）を追加し、
  トップの製品一覧・ヒーローカルーセル・ナビに他製品と同じ形式で登録する。
- 言語切替（`LanguageSwitcher`）と sitemap が ja/en 両ページで機能すること。
- デザイン原本を作る場合は `docs/design/dizun-v1/index.html`（実寸・単一HTML）を先に作り、
  承認を得てからコンポーネントへ最小変換する（Clatch v2・Honyac v2 と同じフロー。この場合もまずユーザーに提案すること）。

## DIZUN のファクト（発信してよい内容）

以下はすべて実装・検証済みです（XCTest 25シナリオ、7-Zip/Info-ZIP unzip/ditto/python zipfile との交叉検証）:

- macOS ネイティブの圧縮・解凍・画像最適化アプリ。外部コードに依存しない独自エンジン（DizunCore）
- ZIP 圧縮・解凍: Store/Deflate、ZIP64、UTF-8/CP932（Windows互換）切替、CP932自動検出・手動指定
- 暗号化 ZIP: AES-256（WinZip拡張）と ZipCrypto。暗号化時はエントリ名・構成が漏れない自動二重ZIP化＋自動アンラップ
- 画像最適化: PNG/JPEG のメタ情報削除（画素は完全一致）、長辺リサイズ、JPEG目標サイズ探索、元画像ゴミ箱退避
- Finder統合: `.zip` ダブルクリック解凍、右クリックサービス3種、Dockドロップ（未起動ピン留め対応）
- 解凍前プレビュー（内容一覧・文字コード切替・警告）、ドロップレット窓、UI言語 ja/en
- 安全性: Zip Slip 防御、**既存ファイルの絶対上書き防止**、zip bomb 対策（膨張比・容量・件数リミット）、キャンセル時クリーンアップ
- プライバシー: テレメトリ・広告・解析・アップデート確認・外部API呼び出しは一切なし。すべてローカル完結
- オープンソース: MIT ライセンス、GitHub で開発（https://github.com/DevDog-Lab/dizun）

### 名前のストーリー（ページの核として扱う）

小文字の `unzip` を180度回転させると `dizun` と読める——この反転を名前の核とし、
「解凍（unzip）と圧縮（zip）という逆の操作をひとつに込めた」物語として提示する。
ロゴはこの回転を具現化したワードマーク（白の回転half＋ライトブルーの正位置half）。

### ステータス表記（必須・誇大表現の禁止）

- 現在 **「開発中・未配布」**（コード署名・notarization 未実施、リリースバイナリの配布なし）。
  Clatch の「正式配布準備中」に相当する誠実なステータス表示を行う。
- **Windows 実機での相互運用は未検証**（Mac 上での交叉検証のみ）。Windows での動作保証・互換性の断言は禁止。
- 「固める。開く。迷わない。」は**タグライン候補**であり正式決定ではない。確定扱いで使用しない。
- 未実装の構想（テキストコード変換機能等）を実装済みと表示しない。
- ダウンロード誘導は作らない。CTA は GitHub リポジトリへのリンクのみ。

## ブランド要件

- カラー: アプリ本体に準拠 — ウィンドウ背景 `#4F91DD`（ブランドブルー）、設定パネル `#3B6DA6`（マットブルー）、
  白。既存の dizun ステージングページ（dizun リポジトリ `site/index.html`）の dark 系配色は**旧案**であり踏襲不要。
- ロゴ: dizun リポジトリの `Assets/logo.png`（2329×482 透過ワードマーク）と `Assets/icon-1024.png`。
  サイト用に必要なら `public/brands/dizun/` へコピーして使う（ライセンスは MIT で問題なし）。
  白い回転 half は暗背景で、ライトブルーの正位置 half は明背景で見やすい。背景との組み合わせに注意。
- アニメーション: `unzip` → 180°回転 → `dizun` の短いアニメーションをヒーロー付近に提案する
  （ブランドコンセプトが公式に構想している使い方）。`prefers-reduced-motion` を必ず尊重。
- トーン（ブランドコンセプト§6）: シンプル・確実・静か・国際的。大げさな演出をしない。

## ページ構成の提案（Clatch/Honyac のリズムに準拠・調整可）

1. ヒーロー: ワードマーク＋回転アニメ＋1行リード＋ステータスバッジ（開発中）＋GitHub CTA
2. 名前のストーリー（`unzip`↔`dizun` の反転）
3. 解決する課題（日本語ファイル名の文字化け・OS間交換・上書き事故の不安）
4. できること（機能カード: ZIP / 暗号化 / 画像最適化 / Finder統合 / 安全性）
5. デモ・スクリーンショット（後述）
6. プライバシー（ローカル完結・通信なし）
7. FAQ（配布時期・Windows対応・料金→無料・OSSについて 等、事実の範囲で）
8. クロージング＋GitHub リンク

## スクリーンショット

実アプリの実機スクリーンショットを使用する（再現図ではなく）。撮影手順:

1. `/Volumes/Development/DevDog-Lab/dizun` で `./scripts/build-app.sh` を実行（/Applications/DIZUN.app が更新される）
2. アプリを起動し、ドロップレット窓の ZIP タブ・画像最適化タブを表示
3. ウィンドウ矩形に限定してキャプチャ（画面全体を撮らないこと。`screencapture -l <windowid>` または同等手段）
4. 明るい背景（ブランドブルー地）に白パネルが映える構図で2〜3枚。`public/brands/dizun/` に配置

撮影したスクリーンショットに秘密情報・個人情報・他アプリの内容が写っていないことを確認してから使うこと。

## 制約

- アナリティクス・トラッカー・外部CDN・外部フォント・サードパーティスクリプトは禁止（サイト全体の既定）。
- 上記「ファクト」節以外の機能・互換性・日程の言及はしない。
- デプロイ・本番反映（devdog-lab.com への公開）はユーザーの明示指示まで行わない。実装とビルド検証まで。

## 検収条件

- `npm run build`（`astro check && astro build`）が警告なしで通ること（site ディレクトリ内で）。
- `/ja/dizun/` と `/en/dizun/` の両方が表示され、言語切替が往復できること。
- トップページ・サイトナビに DIZUN が他製品と同じ形式で登録されていること。
- OGP 画像・タイトル・description が設定されていること。
- リンク切れがないこと（GitHub リポジトリ URL は https://github.com/DevDog-Lab/dizun）。
- 実装は作業ブランチで行い、コミットはローカルまで（push はユーザー指示待ち）。

## 進め方

1. まず `src/content/dizun.ts` にコピー（ja/en）を起こし、ページ構成案とあわせてユーザーに提示する
2. 承認後に `DizunLanding.astro` とページ2枚・トップ登録・OGP を実装する
3. スクリーンショットを撮影して組み込む
4. ビルド検証・`astro preview` での目視確認をして報告する
