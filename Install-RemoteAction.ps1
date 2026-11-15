<#
.SYNOPSIS
    RemoteAction / TakeScreenshot タスクをタスクスケジューラに登録（または削除）します。

.DESCRIPTION
    このスクリプトが置かれたフォルダーの絶対パスを自動で求め、
    ログイン中ユーザーの画面上で動くタスク（対話型ログオン）として登録します。
    フォルダーを移動したときは、もう一度実行して登録し直してください。

    トリガーは設定しません。タスクは schtasks /Run（Invoke-RemoteAction.ps1）で起動したときだけ動きます。

.PARAMETER Task
    登録するタスク。RemoteAction（既定）/ TakeScreenshot。両方指定することもできます。

.PARAMETER Uninstall
    登録したタスクを削除します。

.EXAMPLE
    # RemoteAction タスクを登録する
    .\Install-RemoteAction.ps1

.EXAMPLE
    # 両方のタスクを登録する
    .\Install-RemoteAction.ps1 -Task RemoteAction, TakeScreenshot

.EXAMPLE
    # 削除する
    .\Install-RemoteAction.ps1 -Task RemoteAction, TakeScreenshot -Uninstall

.EXAMPLE
    # 何が行われるかだけを表示する
    .\Install-RemoteAction.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Task = @('RemoteAction'),

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# タスク名と、そのタスクが起動するスクリプト
$scripts = [ordered]@{
    RemoteAction   = 'Remote-Action.ps1'
    TakeScreenshot = 'Take-Screenshot.ps1'
}

# powershell -File で呼ぶと "A,B" が1つの文字列で渡されるので、カンマで分けてから確かめる
$Task = @($Task -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $Task) {
    if (-not $scripts.Contains($name)) {
        throw "不明なタスク名です: '$name'（$($scripts.Keys -join ' / ')）"
    }
}

$baseDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$userId  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

foreach ($name in $Task) {
    $existing = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue

    if ($Uninstall) {
        if (-not $existing) {
            Write-Host "タスク '$name' は登録されていません"
            continue
        }
        if ($PSCmdlet.ShouldProcess($name, 'タスクを削除')) {
            Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false
            Write-Host "タスク '$name' を削除しました"
        }
        continue
    }

    $scriptPath = Join-Path $baseDir $scripts[$name]
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "スクリプトが見つかりません: $scriptPath"
    }

    # パスに空白が含まれても動くよう、-File の値は二重引用符で囲む
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $baseDir
    # Interactive = ログイン中のユーザーの画面上で動かす（schtasks の /IT と同じ）。パスワードは保存しない
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                     -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew

    $verb = if ($existing) { 'タスクを登録し直す' } else { 'タスクを登録' }
    if ($PSCmdlet.ShouldProcess("$name -> $scriptPath", $verb)) {
        Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Principal $principal `
            -Settings $settings -Description 'ログイン中のデスクトップで remote-action のスクリプトを実行します' -Force | Out-Null
        Write-Host "タスク '$name' を登録しました"
        Write-Host "  実行ユーザー: $userId"
        Write-Host "  スクリプト  : $scriptPath"
    }
}
