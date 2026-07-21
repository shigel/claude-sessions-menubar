---
name: deploy
description: ClaudeSessions.appをビルドし、実行中のインスタンスを止めて/Applicationsへ再配置、起動し直す。「デプロイして」「入れ替えて」「反映して」で使う。
---

# デプロイ

`claude-sessions-menubar` の変更を `/Applications/ClaudeSessions.app` に反映する。

## 手順

```
bash scripts/deploy.sh
```

これで以下を一括実行する:
1. `scripts/build-app.sh`(`swift build -c release` → `.app`組み立て → `ClaudeSessions Dev Signer`証明書で署名)
2. 実行中の`ClaudeSessions`プロセスを`pkill`で停止
3. `/Applications/ClaudeSessions.app`を新しいビルドで置き換え
4. `open`で再起動、`ps`で起動確認

## 権限リセットが必要になるケース

コード署名の identity(`ClaudeSessions Dev Signer`)を変えた場合、または `tccutil reset` を手動で行った場合のみ、
再度システム設定でアクセシビリティ/入力監視の許可が必要になる。通常のコード変更→デプロイでは
同じ証明書で署名され続けるため、権限は保持され再許可は不要。
