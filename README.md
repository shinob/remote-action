# Remote-Action の使い方（リモートからのクリック・文字入力・スクリーンショット）

SSH や Claude Code から、ログイン中のデスクトップを操作するための仕組みです。
指定した座標のマウスクリック、文字やキーの入力、スクリーンショットの撮影ができます。

## なぜタスクスケジューラを使うのか

SSH（Windows の OpenSSH サーバー）や Claude Code から実行したコマンドは **Session 0** で動きます。
Session 0 からはログイン中のデスクトップ画面にアクセスできないため、クリックも撮影もできません。

そこで、ログイン中ユーザーの画面上で動くタスク（`/IT` 付き）を登録しておきます。
操作の内容は **指示ファイル（request.json）** で渡します（方法 A）。
`schtasks /Run` では実行のたびに引数を渡せないためです。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `Install-RemoteAction.ps1` | タスクの登録・削除。スクリプトの置き場所（絶対パス）は自動で調べる |
| `Invoke-RemoteAction.ps1` | 呼び出し側（SSH / Claude Code）で使う。指示ファイルを作り、タスクを起動し、結果を表示する |
| `Remote-Action.ps1` | タスクから起動される。指示ファイルを読んで、クリックや撮影を実際に行う |
| `Take-Screenshot.ps1` | スクリーンショットの撮影処理（`Remote-Action.ps1` から呼ばれる） |
| `Take-Screenshot.md` | `Take-Screenshot.ps1` を単独で使うときの説明 |
| `.gitignore` | `data\` と `screenshots\` を git の管理から外す |
| `data\request.json` | 指示ファイル。読み込まれると `last-request.json` に移動される |
| `data\result.json` | 最後に実行した操作の結果 |
| `data\remote-action.log` | 実行履歴 |
| `screenshots\` | 撮影した画像の保存先 |

`data\` と `screenshots\` は実行時に自動で作られます。入力した文字列や画面の画像が含まれるため、git では管理しません。

以下の説明に出てくる `<配置先>` は、このフォルダー（スクリプト一式）を置いた場所の絶対パスに置き換えてください（例: `C:\Tools\remote-action`）。

## 1. タスクを登録する（最初の1回だけ）

操作される側の PC に、操作するユーザーとしてログインした状態で、`Install-RemoteAction.ps1` を実行します。SSH 経由で実行してもかまいません。スクリプトが自分の置かれたフォルダーの絶対パスを調べて、タスクに設定します。

```powershell
cd <配置先>
powershell -ExecutionPolicy Bypass -File .\Install-RemoteAction.ps1
```

- ログイン中のユーザーの画面上で動くタスク（対話型ログオン、schtasks の `/IT` と同じ）として登録します。パスワードは保存しません
- トリガー（自動実行の設定）は付けません。`Invoke-RemoteAction.ps1` が起動したときだけ動きます
- すでに同じ名前のタスクがあれば上書きします。フォルダーを移動したときは、もう一度実行してください
- `-WhatIf` を付けると、登録せずに、何が行われるかだけを表示します
- `Take-Screenshot.ps1` を単独で動かすタスクも必要なら `-Task RemoteAction,TakeScreenshot` を付けます（[Take-Screenshot.md](Take-Screenshot.md) を参照）

不要になったら削除します。

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RemoteAction.ps1 -Uninstall
```

<details>
<summary>スクリプトを使わずに schtasks で登録する場合</summary>

`<配置先>` を、このフォルダーの絶対パスに置き換えて実行します。絶対パスは、このフォルダーで次のコマンドを実行すると分かります。

```powershell
(Get-Location).Path
```

```
schtasks /Create /TN "RemoteAction" /SC ONCE /ST 00:00 /IT /F /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File <配置先>\Remote-Action.ps1"
schtasks /Delete /TN "RemoteAction" /F
```

- `/IT` を付けると、ログイン中のユーザーの画面上でタスクが動きます
- `/SC ONCE /ST 00:00` は登録に必要なだけの指定です。この設定で自動実行されることはありません
- パスに空白が含まれる場合は引用符の扱いが難しくなるので、`Install-RemoteAction.ps1` を使ってください

</details>

## 2. 操作を実行する

`<配置先>` で実行します。SSH から実行する場合は、先頭に `powershell -ExecutionPolicy Bypass -File` を付けてください。

```powershell
# スクリーンショットだけを撮る
.\Invoke-RemoteAction.ps1 -Screenshot

# (1858, 228) を左クリックする
.\Invoke-RemoteAction.ps1 -X 1858 -Y 228

# クリックして、1秒後にスクリーンショットを撮る（結果の確認用）
.\Invoke-RemoteAction.ps1 -X 1858 -Y 228 -Screenshot

# 右クリック
.\Invoke-RemoteAction.ps1 -X 500 -Y 300 -Button right

# ダブルクリックして、マウスを元の位置に戻す
.\Invoke-RemoteAction.ps1 -X 500 -Y 300 -Double -ReturnCursor

# (300, 200) から (800, 450) へドラッグして、撮影する
.\Invoke-RemoteAction.ps1 -X 300 -Y 200 -ToX 800 -ToY 450 -Screenshot

# 入力欄をクリックして、文字を入力する
.\Invoke-RemoteAction.ps1 -X 700 -Y 147 -Text "hello"

# 入力欄をクリックし、中身を消してから入力し、Enter を押して撮影する
.\Invoke-RemoteAction.ps1 -X 700 -Y 147 -ClearFirst -Text "サンプル" -PressEnter -Screenshot

# クリックせずに、今フォーカスがある場所に入力する
.\Invoke-RemoteAction.ps1 -Text "abc" -PressEnter
```

`-X`/`-Y` と `-Text` を両方指定すると、次の順に実行します。

1. クリック
2. 0.3 秒待つ（入力欄にフォーカスが移るのを待つ）
3. `-ClearFirst` があれば Ctrl+A → Delete
4. `-Text` の文字を入力
5. `-PressEnter` があれば Enter
6. `-Screenshot` があれば `-WaitMs` だけ待って撮影

Enter 以外のキー（Tab、Esc、Ctrl+S など）を押したいときは、`-Json` で `key` を指定します。

### Invoke-RemoteAction.ps1 のパラメーター

| パラメーター | 既定値 | 説明 |
|---|---|---|
| `-X`, `-Y` | なし | クリックする座標（全モニター撮影のスクリーンショット画像上のピクセル座標） |
| `-Button` | `left` | `left` / `right` / `middle` |
| `-Double` | なし | ダブルクリックする |
| `-ReturnCursor` | なし | クリック（ドラッグ）後にマウスを元の位置に戻す |
| `-ToX`, `-ToY` | なし | ドラッグの終了座標。指定すると `-X`/`-Y` をクリックする代わりに、そこから `-ToX`/`-ToY` までドラッグする（`-Button` で使うボタンを選べる。`-Double` とは同時に使えない） |
| `-DurationMs` | `500` | ドラッグの移動にかける時間（ミリ秒） |
| `-Text` | なし | 入力する文字列（日本語可）。クリックしない場合は、今フォーカスがある場所に入力する |
| `-ClearFirst` | なし | 入力の前に Ctrl+A → Delete で既存の文字を消す |
| `-PressEnter` | なし | 入力の後に Enter を押す |
| `-Screenshot` | なし | スクリーンショットを撮る。ほかの操作と一緒に指定すると、最後に撮る |
| `-WaitMs` | `1000` | 最後の操作からスクリーンショットまでの待ち時間（ミリ秒） |
| `-Json` | なし | 操作の並びを JSON で直接指定する（指定すると上のパラメーターは無視） |
| `-TimeoutSec` | `30` | 結果を待つ最大秒数。指示に含まれる待ち時間（`wait` の `ms`、`click` の `delayMs`）の合計は自動で上乗せされる |

## 指示ファイル（request.json）の書式

`-Json` で渡す場合や、指示ファイルを直接書く場合の書式です。操作は上から順に実行し、途中で失敗するとそこで止まります。

```json
{
  "id": "任意の識別子",
  "actions": [
    { "action": "click", "x": 700, "y": 147 },
    { "action": "wait", "ms": 300 },
    { "action": "key", "keys": "Ctrl+A" },
    { "action": "type", "text": "サンプル" },
    { "action": "key", "keys": "Tab" },
    { "action": "wait", "ms": 500 },
    { "action": "screenshot" }
  ]
}
```

| action | 項目 | 説明 |
|---|---|---|
| `click` | `x`, `y` | クリックする座標（必須。全モニター撮影の画像上の座標） |
| | `button` | `left` / `right` / `middle`（既定 `left`） |
| | `double` | `true` でダブルクリック |
| | `delayMs` | クリック前の待ち時間（ミリ秒） |
| | `returnCursor` | `true` でクリック後にマウスを元の位置に戻す |
| `drag` | `x`, `y` | ドラッグの開始座標（必須。全モニター撮影の画像上の座標） |
| | `toX`, `toY` | ドラッグの終了座標（必須） |
| | `button` | `left` / `right` / `middle`（既定 `left`） |
| | `steps` | 終了位置までの移動を何回に分けるか（既定 20） |
| | `durationMs` | 移動にかける時間（ミリ秒、既定 500） |
| | `holdMs` | ボタンを押してから動き始めるまでの待ち時間（ミリ秒、既定 200） |
| | `delayMs`, `returnCursor` | `click` と同じ |
| `type` | `text` | 入力する文字列（必須。日本語可。改行は Enter、タブは Tab として送る） |
| | `intervalMs` | 1文字ごとの間隔（ミリ秒、既定 10） |
| `key` | `keys` | 押すキー。`Enter` `Tab` `Esc` `Backspace` `Delete` `Home` `End` `Up` `Down` `Left` `Right` `F1`〜`F12` `Space` や英数字1文字。`+` でつなぐと同時押し（`Ctrl+A` `Ctrl+S` `Shift+Tab` `Alt+F4` など） |
| `wait` | `ms` | 待ち時間（ミリ秒、既定 1000） |
| `screenshot` | `mode` | `All`（全モニター、既定）/ `Primary`（メインモニターのみ） |

## 結果（result.json）の例

```json
{
  "id": "…",
  "success": true,
  "startedAt": "2026-11-15T15:40:00.000+09:00",
  "finishedAt": "2026-11-15T15:40:01.300+09:00",
  "error": null,
  "steps": [
    { "action": "click", "success": true, "x": 1858, "y": 228, "screenX": 1858, "screenY": 228, "button": "left", "double": false },
    { "action": "wait", "success": true, "ms": 1000 },
    { "action": "screenshot", "success": true, "file": "<配置先>\\screenshots\\screenshot_….png" }
  ]
}
```

## 座標の調べ方

1. `-Screenshot` でスクリーンショットを撮ります（全モニターを1枚に撮影します）
2. 画像をペイントなどで開き、クリックしたい位置のピクセル座標を読み取ります（ペイントでは左下に表示されます）
3. その座標をそのまま `-X` / `-Y` に指定します

スクリプトは高 DPI 対応にしてあるので、拡大率 125% などの環境でも画像の座標とクリック位置が一致します。

モニターが複数あっても、座標は常に「全モニター画像の左上を (0, 0) とした値」で指定します。メインモニターより左や上にモニターがある場合の画面座標への変換（負の座標になる分の補正）は、スクリプトが自動で行います。`result.json` の `screenX` / `screenY` が、実際にクリックした画面座標です。

## 注意点

- タスクを登録したユーザーが、その PC にログインしている必要があります
- 画面がロック中・スリープ中は操作できません。リモートデスクトップで入っていて、切断したままのセッションも同様です
- **管理者権限で動いているウィンドウ**はクリックできません（Windows のセキュリティ機能 UIPI による制限）
- ウィンドウの位置や大きさが変わると、同じ座標でも別の場所をクリックしてしまいます。クリックの直前にスクリーンショットで位置を確認してください
- 画像の範囲外の座標を指定すると、クリックせずにエラーになります
- ドラッグがアプリに認識されないとき（選択されない、部品がつかめない など）は、`-Json` で `holdMs` を長くする、`durationMs` と `steps` を増やしてゆっくり動かす、を試してください。途中で失敗しても、マウスボタンは必ず離します
- 文字は Unicode として直接送るので、日本語入力（IME）のオン・オフに関係なく、指定した文字がそのまま入ります。ただし、アプリによっては Unicode 入力を受け付けないことがあります
- キー入力は、その時点でフォーカスがあるウィンドウに送られます。クリックで目的の入力欄にフォーカスが移ったことを、スクリーンショットで確認してください
- SSH から日本語を `-Text` で渡すと、文字コードの違いで文字化けすることがあります。その場合は、指示ファイル（UTF-8）を直接書いてください
- **`type` で入力した文字列は `data\last-request.json` に平文で残ります**（ログと `result.json` には文字数だけが残ります）。パスワードなど人に見られて困る文字列を入力したときは、実行後に `last-request.json` を削除してください
- `type` の入力にかかる時間（文字数 × `intervalMs`）は、結果を待つ時間に上乗せされません。数百文字を超える入力では `-TimeoutSec` を延ばしてください
- `key` の `keys` では `+` を区切りに使うため、`+` キーそのものは指定できません。`+` を入力したいときは `type` を使います
- **メニュー・ドロップダウン・右クリックメニューは、開く操作と選ぶ操作を1回の指示（`-Json`）にまとめてください。** 指示を実行するたびに PowerShell が起動してアプリのフォーカスが外れるため、開いたメニューが次の指示の前に閉じてしまいます（OpenPLC Editor の Device 選択、ラダーの部品メニューなどで確認）。項目の上にマウスが動いてからでないと選択を受け付けないものは、見出しなど項目以外の場所を一度クリックしてから項目をクリックします

  ```json
  {"actions":[
    {"action":"click","x":660,"y":202},
    {"action":"wait","ms":600},
    {"action":"click","x":560,"y":280},
    {"action":"wait","ms":300},
    {"action":"click","x":583,"y":331}
  ]}
  ```
- `request.json` に書き込めるプロセスなら誰でもデスクトップを操作できます。使い終わったらタスクを削除してください
- 同時に複数の操作を実行しないでください（指示ファイルは1つだけです）
- スクリプトは BOM 付き UTF-8 で保存しています。編集するときもこの文字コードのまま保存してください
