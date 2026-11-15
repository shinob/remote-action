# Take-Screenshot.ps1 の使い方

画面のスクリーンショットを撮影して画像ファイルに保存する PowerShell スクリプトです。

## できること

- 全モニターをまとめて撮影（既定）、またはメインモニターだけを撮影
- 保存形式は PNG / JPG / BMP から選択
- 指定した秒数だけ待ってから撮影
- 撮影の間だけ、スクリプトを実行しているコンソール窓を最小化
- 拡大率 125% などの高 DPI 環境でも、画面全体を正しく撮影

保存先は、既定ではスクリプトと同じ場所にある `screenshots\` フォルダーです。フォルダーがなければ自動で作成されます。ファイル名は `screenshot_yyyyMMdd_HHmmss_fff.png` の形式になります。

以下の説明に出てくる `<配置先>` は、このスクリプトを置いたフォルダーの絶対パスに置き換えてください（例: `C:\Tools\remote-action`）。

## パラメーター

| パラメーター | 値 | 既定値 | 説明 |
|---|---|---|---|
| `-Mode` | `All` / `Primary` | `All` | `All` は全モニター、`Primary` はメインモニターのみ |
| `-OutDir` | フォルダーのパス | `<スクリプトの場所>\screenshots` | 保存先 |
| `-Format` | `png` / `jpg` / `bmp` | `png` | 保存形式 |
| `-Delay` | 0〜3600 | `0` | 撮影までに待つ秒数 |
| `-HideConsole` | （スイッチ） | なし | 撮影前にコンソール窓を最小化し、撮影後に元に戻す |

## ローカルで実行する

デスクトップで開いたコマンドプロンプトや PowerShell から実行します。

```powershell
cd <配置先>

# すぐに全画面を撮影
powershell -ExecutionPolicy Bypass -File .\Take-Screenshot.ps1

# コンソール窓を隠し、5秒後に撮影
powershell -ExecutionPolicy Bypass -File .\Take-Screenshot.ps1 -Delay 5 -HideConsole

# メインモニターだけを JPG で保存
powershell -ExecutionPolicy Bypass -File .\Take-Screenshot.ps1 -Mode Primary -Format jpg
```

> **Windows Terminal を使う場合**
> `-HideConsole` を付けても窓が最小化されないことがあります。その場合は `-Delay 5` だけを付けて実行し、待っている間に手動で窓を最小化してください。

## SSH や Claude Code から直接実行すると撮影できない理由

SSH 接続（Windows の OpenSSH サーバー）や Claude Code から実行したコマンドは、**Session 0** で動きます。Session 0 は Windows のサービスが使う、画面を持たない領域です。ログイン中のデスクトップ画面にはアクセスできないため、次のエラーで失敗します。

```
Exception calling "CopyFromScreen" with "3" argument(s): "The handle is invalid"
```

そこで、タスクスケジューラを使ってログイン中のユーザーの画面上でスクリプトを動かします。

## SSH から好きなタイミングで撮影する手順

### 1. タスクを登録する（最初の1回だけ）

撮影される側の PC に、撮影するユーザーとしてログインした状態で、次のコマンドを実行します。SSH 経由で実行してもかまいません。`Install-RemoteAction.ps1` が、自分の置かれたフォルダーの絶対パスを調べてタスクに設定します。

```powershell
cd <配置先>
powershell -ExecutionPolicy Bypass -File .\Install-RemoteAction.ps1 -Task TakeScreenshot
```

- ログイン中のユーザーの画面上で動くタスク（対話型ログオン、schtasks の `/IT` と同じ）として登録します
- トリガー（自動実行の設定）は付けません。`schtasks /Run` で起動したときだけ動きます
- すでに同じ名前のタスクがあれば上書きします。フォルダーを移動したときは、もう一度実行してください

スクリプトを使わずに登録する場合は、`<配置先>` を絶対パス（このフォルダーで `(Get-Location).Path` を実行すると分かります）に置き換えて、次を実行します。

```
schtasks /Create /TN "TakeScreenshot" /SC ONCE /ST 00:00 /IT /F /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File <配置先>\Take-Screenshot.ps1"
```

### 2. SSH から撮影する

```
schtasks /Run /TN "TakeScreenshot"
```

数秒後に `<配置先>\screenshots\` に画像が保存されます。

最新の1枚を確認する場合は、次のコマンドを使います。

```powershell
Get-ChildItem <配置先>\screenshots | Sort-Object LastWriteTime | Select-Object -Last 1
```

### 3. 手元の PC に画像を取ってくる

手元の PC で実行します。

```
scp <ユーザー名>@<ホスト>:<配置先>/screenshots/*.png .
```

### タスクが不要になったら削除する

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RemoteAction.ps1 -Task TakeScreenshot -Uninstall
```

（schtasks で登録した場合は `schtasks /Delete /TN "TakeScreenshot" /F`）

## 注意点

- タスクを登録したユーザーが、撮影される側の PC にログインしている必要があります
- 画面がロック中・スリープ中だと、ロック画面や真っ黒な画像になるか、撮影に失敗します
- リモートデスクトップで入っていて、切断したままのセッションも撮影できません
- 起動の一瞬だけ PowerShell の窓が表示されることがあり、まれに画像に写り込む場合があります
- Windows PowerShell 5.1 で日本語が文字化けしないよう、スクリプトは BOM 付き UTF-8 で保存しています。編集するときもこの文字コードのまま保存してください
