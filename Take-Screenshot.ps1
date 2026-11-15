<#
.SYNOPSIS
    画面のスクリーンショットを撮影して画像ファイルに保存します。

.PARAMETER Mode
    All     : 全モニター（仮想スクリーン全体）を撮影（既定）
    Primary : プライマリモニターのみ撮影

.PARAMETER OutDir
    保存先フォルダー（既定: スクリプトと同じ場所の screenshots フォルダー）

.PARAMETER Format
    png / jpg / bmp（既定: png）

.PARAMETER Delay
    撮影までの待ち秒数（既定: 0）

.PARAMETER HideConsole
    撮影前にこのスクリプトを実行しているコンソール窓を最小化し、撮影後に元に戻す

.EXAMPLE
    .\Take-Screenshot.ps1
    .\Take-Screenshot.ps1 -Delay 5 -HideConsole
    .\Take-Screenshot.ps1 -Mode Primary -Delay 3
    .\Take-Screenshot.ps1 -Format jpg -OutDir C:\temp\shots
#>
param(
    [ValidateSet('All', 'Primary')]
    [string]$Mode = 'All',

    [string]$OutDir = (Join-Path $PSScriptRoot 'screenshots'),

    [ValidateSet('png', 'jpg', 'bmp')]
    [string]$Format = 'png',

    [ValidateRange(0, 3600)]
    [int]$Delay = 0,

    [switch]$HideConsole,

    # 保存したファイルのパスをパイプラインに出力する（他スクリプトからの呼び出し用）
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# 高DPI（拡大率 125% など）環境で画面の一部しか写らない問題を防ぐ
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class Win32Helper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("kernel32.dll")]
    public static extern System.IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
}
'@
[void][Win32Helper]::SetProcessDPIAware()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$consoleHwnd = [IntPtr]::Zero
if ($HideConsole) {
    $consoleHwnd = [Win32Helper]::GetConsoleWindow()
}

if ($Delay -gt 0) {
    Write-Host "$Delay 秒後に撮影します..."
}

if ($consoleHwnd -ne [IntPtr]::Zero) {
    [void][Win32Helper]::ShowWindow($consoleHwnd, 6)   # SW_MINIMIZE
}

# 最小化アニメーションが終わるのを少し待つ
$waitMs = $Delay * 1000
if ($HideConsole -and $waitMs -lt 500) { $waitMs = 500 }
if ($waitMs -gt 0) { Start-Sleep -Milliseconds $waitMs }

$bounds = if ($Mode -eq 'Primary') {
    [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
} else {
    [System.Windows.Forms.SystemInformation]::VirtualScreen
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$filePath  = Join-Path $OutDir "screenshot_$timestamp.$Format"

$imageFormat = switch ($Format) {
    'png' { [System.Drawing.Imaging.ImageFormat]::Png }
    'jpg' { [System.Drawing.Imaging.ImageFormat]::Jpeg }
    'bmp' { [System.Drawing.Imaging.ImageFormat]::Bmp }
}

$bitmap   = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($filePath, $imageFormat)
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
    if ($consoleHwnd -ne [IntPtr]::Zero) {
        [void][Win32Helper]::ShowWindow($consoleHwnd, 9)   # SW_RESTORE
    }
}

Write-Host "保存しました: $filePath ($($bounds.Width)x$($bounds.Height))"
if ($PassThru) { $filePath }
