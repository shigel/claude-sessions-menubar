# Claude Sessions (menu bar app)

Claude Code の `~/.claude/projects/` に記録されたセッション（プロジェクトディレクトリ）を
メニューバーから一覧・検索し、対応する VSCode / Cursor のウィンドウをフォーカスするか、
開いていなければ新規に開くための、ネイティブ macOS menu bar 常駐アプリです。

Raycast拡張版 (`claude-code-sessions`) と同等の機能を、Raycast・npm 不要のスタンドアロン
`.app` として提供します。配布・共有のしやすさを目的にしています。

## 機能

- メニューバーアイコン（ターミナル記号）クリックでプロジェクト一覧をポップオーバー表示
- 検索フィルタ（プロジェクト名・パスの部分一致）
- クリックで「対応するエディタウィンドウを探してフォーカス」、無ければ「記憶している
  （または既定の）エディタで新規オープン」
- 複数ウィンドウが該当する場合はインラインで選択リストを表示
- 右クリック（コンテキストメニュー）で VSCode / Cursor を指定して開ける。選んだエディタは
  プロジェクトごとに記憶される
- 存在しなくなったプロジェクトパスはグレー表示＋警告アイコン
- アクセシビリティ権限が無い場合は上部にバナー表示（新規オープンは権限なしでも動作）

## ビルド方法

Xcode は不要です。Command Line Tools のみでビルドできます。

```bash
cd claude-sessions-menubar
swift build                 # デバッグビルドの動作確認
swift build -c release      # リリースビルド
bash scripts/build-app.sh   # .app バンドル化 + ad-hoc署名 + zip化 (dist/ に出力)
```

`scripts/build-app.sh` を実行すると以下が生成されます。

- `dist/ClaudeSessions.app`
- `dist/ClaudeSessions.zip`（配布用）

## 初回起動手順

ad-hoc 署名（Apple Developer 証明書なし）のため、初回起動時に Gatekeeper の警告が出ます。

1. `dist/ClaudeSessions.app` を `/Applications` などにコピー
2. Finder で **右クリック → 「開く」** を選択（ダブルクリックだと「開発元を確認できません」と
   拒否されることがあります）
3. 確認ダイアログで「開く」を選択

zip で配布された場合は quarantine 属性が付与されているため、次のコマンドで解除してから
起動してください。

```bash
xattr -d com.apple.quarantine /Applications/ClaudeSessions.app
```

## アクセシビリティ権限の許可

ウィンドウ一覧の取得・フォーカス（AXRaise）には、System Events を操作するための
**アクセシビリティ権限**が必要です。

1. アプリ起動後、ポップオーバー上部の「アクセシビリティ権限がありません」バナーの
   「システム設定を開く」ボタンを押す
   （または手動で **システム設定 → プライバシーとセキュリティ → アクセシビリティ**）
2. 一覧に `ClaudeSessions` を追加し、チェックをオンにする
3. アプリを再起動すると反映されます

権限が無い状態でも、エディタでの新規オープン（`open -a`）自体は動作します。ウィンドウの
検出・フォーカスのみが制限されます。

## 既知の制約

- ad-hoc 署名のため、配布先の Mac では毎回 Gatekeeper 警告が出ます（Apple Developer 証明書
  による正式な署名・公証は行っていません）
- 対応エディタは VSCode / Cursor のみです。`Sources/ClaudeSessions/EditorRegistry.swift` に
  `EditorDef` を追加すれば拡張できます
- ウィンドウタイトルの照合はプロジェクトディレクトリの basename との完全一致（em dash /
  ハイフン区切り）に依存しています。エディタのウィンドウタイトル表示形式が変わると
  マッチしなくなる可能性があります

## ソース構成

```
Package.swift
Sources/ClaudeSessions/
  main.swift              // NSApplication起動
  AppDelegate.swift        // NSStatusItem / NSPopover 管理
  SessionScanner.swift     // ~/.claude/projects 走査
  EditorRegistry.swift     // VSCode/Cursor 定義
  WindowController.swift   // osascript 経由の窓一覧/フォーカス/open -a
  PreferenceStore.swift    // UserDefaults によるエディタ記憶
  SessionListView.swift    // SwiftUI: 検索欄+リスト+ウィンドウ選択+右クリックメニュー
scripts/
  build-app.sh             // ビルド+.app組み立て+ad-hoc署名+zip
Resources/Info.plist
```
