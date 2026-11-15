<#
.SYNOPSIS
    RemoteAction タスク経由で、デスクトップ上のクリックやスクリーンショットを実行します。
    SSH や Claude Code など、デスクトップに直接アクセスできない環境から使います。

.DESCRIPTION
    1. 指示ファイル（data\request.json）を作成
    2. schtasks /Run で RemoteAction タスクを起動
    3. result.json が書き出されるのを待って、結果を表示

.EXAMPLE
    # スクリーンショットだけを撮る
    .\Invoke-RemoteAction.ps1 -Screenshot

.EXAMPLE
    # (1858, 228) を左クリックし、1秒後にスクリーンショットを撮る
    .\Invoke-RemoteAction.ps1 -X 1858 -Y 228 -Screenshot

.EXAMPLE
    # 右クリック / ダブルクリック / クリック後にマウスを元の位置に戻す
    .\Invoke-RemoteAction.ps1 -X 500 -Y 300 -Button right
    .\Invoke-RemoteAction.ps1 -X 500 -Y 300 -Double -ReturnCursor

.EXAMPLE
    # 入力欄をクリックし、中身を消してから文字を入力し、Enter を押して撮影する
    .\Invoke-RemoteAction.ps1 -X 700 -Y 147 -ClearFirst -Text "サンプル" -PressEnter -Screenshot

.EXAMPLE
    # JSON で操作の並びを直接指定する
    .\Invoke-RemoteAction.ps1 -Json '{"actions":[{"action":"click","x":100,"y":200},{"action":"wait","ms":500},{"action":"screenshot"}]}'
#>
param(
    [Nullable[int]]$X,
    [Nullable[int]]$Y,

    [ValidateSet('left', 'right', 'middle')]
    [string]$Button = 'left',

    [switch]$Double,
    [switch]$ReturnCursor,

    # クリックの後に入力する文字列（クリックしない場合は、今フォーカスがある場所に入力）
    [string]$Text,

    # 入力の前に Ctrl+A → Delete で既存の文字を消す
    [switch]$ClearFirst,

    # 入力の後に Enter を押す
    [switch]$PressEnter,

    # クリックの後（クリックしない場合は単独で）スクリーンショットを撮る
    [switch]$Screenshot,

    # クリックからスクリーンショットまでの待ち時間（ミリ秒）
    [int]$WaitMs = 1000,

    # 操作の並びを JSON で直接指定する（指定すると上のパラメーターは無視）
    [string]$Json,

    [string]$TaskName = 'RemoteAction',
    [string]$WorkDir = (Join-Path $PSScriptRoot 'data'),
    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

$requestPath = Join-Path $WorkDir 'request.json'
$resultPath  = Join-Path $WorkDir 'result.json'

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
}

$id = [guid]::NewGuid().ToString()

if ($Json) {
    $request = $Json | ConvertFrom-Json
    $request | Add-Member -NotePropertyName id -NotePropertyValue $id -Force
} else {
    $actions = @()
    if (($null -ne $X) -xor ($null -ne $Y)) {
        throw '-X と -Y は両方指定してください'
    }
    if ($null -ne $X) {
        $actions += [ordered]@{
            action       = 'click'
            x            = $X
            y            = $Y
            button       = $Button
            double       = [bool]$Double
            returnCursor = [bool]$ReturnCursor
        }
    }
    $hasInput = $Text -or $ClearFirst -or $PressEnter
    if ($hasInput -and $null -ne $X) {
        # クリックで入力欄にフォーカスが移るのを待つ
        $actions += [ordered]@{ action = 'wait'; ms = 300 }
    }
    if ($ClearFirst) {
        $actions += [ordered]@{ action = 'key'; keys = 'Ctrl+A' }
        $actions += [ordered]@{ action = 'key'; keys = 'Delete' }
    }
    if ($Text) {
        $actions += [ordered]@{ action = 'type'; text = $Text }
    }
    if ($PressEnter) {
        $actions += [ordered]@{ action = 'key'; keys = 'Enter' }
    }
    if ($Screenshot -and $actions.Count -gt 0) {
        $actions += [ordered]@{ action = 'wait'; ms = $WaitMs }
    }
    if ($Screenshot) {
        $actions += [ordered]@{ action = 'screenshot' }
    }
    if ($actions.Count -eq 0) {
        throw '操作がありません。-X/-Y、-Text、-Screenshot、-Json のいずれかを指定してください'
    }
    $request = [ordered]@{ id = $id; actions = $actions }
}

# 前回の結果を消してから、指示ファイルを書き出す
if (Test-Path $resultPath) { Remove-Item $resultPath -Force }
$tmp = "$requestPath.tmp"
$request | ConvertTo-Json -Depth 5 | Out-File -FilePath $tmp -Encoding utf8
Move-Item -Path $tmp -Destination $requestPath -Force

schtasks /Run /TN $TaskName | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "タスク '$TaskName' を起動できませんでした（登録されているか確認してください）"
}

# 指示に含まれる待ち時間（wait の ms、click の delayMs）の合計を、待つ時間に上乗せする
$plannedMs = 0
$plannedActions = @(if ($request.actions) { $request.actions } else { $request })
foreach ($a in $plannedActions) {
    if ($a.action -eq 'wait') { $plannedMs += $(if ($null -ne $a.ms) { [int]$a.ms } else { 1000 }) }
    if ($a.action -eq 'click' -and $null -ne $a.delayMs) { $plannedMs += [int]$a.delayMs }
}
$deadline = (Get-Date).AddSeconds($TimeoutSec).AddMilliseconds($plannedMs)
$result = $null
while ((Get-Date) -lt $deadline) {
    if (Test-Path $resultPath) {
        try {
            $candidate = Get-Content -Path $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($candidate.id -eq $id) { $result = $candidate; break }
        } catch {
            # 書き込み途中の場合は次の周回で読み直す
        }
    }
    Start-Sleep -Milliseconds 300
}

if ($null -eq $result) {
    throw "$TimeoutSec 秒以内に結果が返りませんでした。画面がロックされていないか、ユーザーがログインしているか確認してください"
}

$result | ConvertTo-Json -Depth 5
if (-not $result.success) { exit 1 }
