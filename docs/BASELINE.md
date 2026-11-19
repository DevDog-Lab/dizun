# ベースライン検証 — 上流候補の変更なしビルド

作成日: 2026-11-19
目的: 監査対象3リポジトリを改変なしでビルドし、環境・手順・結果を再現可能な形で記録する。

## 0. 検証環境

| 項目 | 値 |
| --- | --- |
| macOS | 27.2.1 (Build 26B131) / Darwin arm64 |
| Xcode | 27.2 (Build 27B52) — **ライセンス未同意**（後述） |
| Swift (CommandLineTools) | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), arm64-apple-macosx28.0 |
| cmake | 4.4.4 (Homebrew) |
| gitleaks | **未導入**（brewがXcodeライセンスエラーで失敗。push承認前に公式バイナリで導入する） |

### 環境上の制約（重要）

`sudo xcodebuild -license` が未実行のため、Xcodeツールチェーン（`/usr/bin/cc`、Xcode経由の`swift`、`xcodebuild`、brewのビルド処理）がすべてブロックされる。**ユーザーによる `sudo xcodebuild -license accept` 実行が必要。**

代替として `DEVELOPER_DIR=/Library/Developer/CommandLineTools` を指定し、CLT側のSwift 6.3.3 / clangを用いて検証した。この制約の影響:

- `swift build`（ライブラリ・実行可能ターゲット）: **可能**
- `swift test`: **不可**（CLTにXCTest / Testing モジュールが無い。`no such module 'XCTest'`）
- `xcodebuild`（.app バンドル、Quick Look拡張のパッケージング）: **不可**

## 1. zip-porter v0.14.0（SHA `98684892...`）

```
$ DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build   # research/zip-porter/
Build complete! (30.51s)
$ ./.build/debug/ZipPorter --version
zip-porter dev
```

- 結果: **成功**。全ターゲット（ZipPorterCore / ZipPorter / CZlib shim）が警告なくビルド。
- CLI `--version` はUI起動なしに正常応答（設計どおり）。
- `swift test` はXCTest不在のため実行不可（上記制約）。テストコード・敵対的フィクスチャ12種の存在は確認済み。
- `--help` は実装されておらずGUI起動を試みる（検証時はプロセス停止を確認、GUIは残存せず）。

## 2. crate（SHA `b2cb6012...`）

```
$ DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build   # research/crate/
Build complete! (49.66s)
```

- 結果: **成功**。ArchiveCore / Crate / CrateQuickLook がビルド。README記載の「Command Line Toolsのみでビルド可」を追試できた。
- `.app` 化（build.sh によるInfo.plist・Services登録・Quick Lookバンドル）は `xcodebuild`/`plistbuddy` 依存のため今回未検証。コード上はSwiftPM完結。

## 3. libarchive（SHA `432ab464...`）

```
$ DEVELOPER_DIR=... CC=/Library/Developer/CommandLineTools/usr/bin/cc \
  cmake -S libarchive -B libarchive-build -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_TEST=OFF -DENABLE_OPENSSL=OFF -DENABLE_CPIO=OFF \
        -DENABLE_TAR=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_INSTALL=OFF
$ cmake --build libarchive-build --target archive_static -j 8
[100%] Built target archive_static      # libarchive.a = 1,341,432 bytes
```

- 結果: **成功**（configure + 静的ライブラリのみ）。ただし1回目は `/usr/bin/cc` がXcodeライセンスエラーでconfigure失敗 — CLTのclang明示指定で解決。
- libarchive自身のテストスイート（`-DENABLE_TEST=ON`）は今回は実行していない（時間・スコープ判断。採用判断時には必須とする）。

## 4. 結論

- 3候補とも**変更なしでビルド可能**であることを確認。ビルド手順・成果物は上記のとおり再現可能。
- XCTest実行には Xcode ライセンス同意が必須。DIZUN側も `swift test` によるテスト実行はこの解除後に実施し、それまでは実行可能バイナリによる検証で代替する（WORK_LOGに記録）。
