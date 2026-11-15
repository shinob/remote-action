<#
.SYNOPSIS
    指示ファイル（request.json）を読み込み、デスクトップ上でクリックやスクリーンショットを実行します。

.DESCRIPTION
    タスクスケジューラ（/IT 付きで登録した "RemoteAction" タスク）から起動される前提のスクリプトです。
    SSH や Claude Code は Session 0 で動くためデスクトップを操作できません。
    そこで、このスクリプトをログイン中ユーザーの画面上で動かして操作を代行します。

    request.json の例:
    {
      "id": "任意の識別子",
      "actions": [
        { "action": "click", "x": 1858, "y": 228 },
        { "action": "wait", "ms": 500 },
        { "action": "screenshot" }
      ]
    }

    actions を省略して、1つの操作をトップレベルに直接書くこともできます。
    { "action": "screenshot" }

    アクション:
      click      x, y（必須。全モニター撮影の画像上の座標） / button: left|right|middle（既定 left） / double: true|false
                 delayMs: クリック前の待ち時間 / returnCursor: クリック後にマウスを元の位置に戻す
      type       text: 入力する文字列（日本語可。改行は Enter、タブは Tab として送る）
                 intervalMs: 1文字ごとの間隔（既定 10）
      key        keys: "Enter" "Tab" "Esc" "Ctrl+A" "Shift+Tab" などのキー指定
      wait       ms: 待ち時間（既定 1000）
      screenshot mode: All|Primary（既定 All）

    実行結果は result.json に、履歴は remote-action.log に書き出します。
    読み込んだ request.json は二重実行を防ぐため last-request.json に移動します。
#>
param(
    [string]$RequestPath = (Join-Path $PSScriptRoot 'data\request.json'),
    [string]$ScreenshotDir = (Join-Path $PSScriptRoot 'screenshots')
)

$ErrorActionPreference = 'Stop'

$workDir         = Split-Path $RequestPath -Parent
$resultPath      = Join-Path $workDir 'result.json'
$lastRequestPath = Join-Path $workDir 'last-request.json'
$logPath         = Join-Path $workDir 'remote-action.log'
$screenshotScript = Join-Path $PSScriptRoot 'Take-Screenshot.ps1'

if (-not (Test-Path $workDir)) {
    New-Item -ItemType Directory -Path $workDir | Out-Null
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class RemoteActionNative {
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT {
        public uint type;
        public InputUnion u;
    }

    const uint INPUT_MOUSE = 0;
    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;

    static void Send(INPUT[] inputs) {
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent != inputs.Length) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    static INPUT VkInput(ushort vk, bool up, bool extended) {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (extended ? KEYEVENTF_EXTENDEDKEY : 0);
        return i;
    }

    // 仮想キーを押す／離す
    public static void Key(ushort vk, bool up, bool extended) {
        Send(new INPUT[] { VkInput(vk, up, extended) });
    }

    // 1文字（UTF-16 の1単位）を Unicode で入力する
    public static void UnicodeChar(char c) {
        INPUT down = new INPUT();
        down.type = INPUT_KEYBOARD;
        down.u.ki.wScan = c;
        down.u.ki.dwFlags = KEYEVENTF_UNICODE;
        INPUT up = down;
        up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        Send(new INPUT[] { down, up });
    }

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static void Click(uint downFlag, uint upFlag) {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].u.mi.dwFlags = downFlag;
        inputs[1].type = INPUT_MOUSE;
        inputs[1].u.mi.dwFlags = upFlag;
        Send(inputs);
    }
}
'@

# スクリーンショット画像のピクセル座標と、クリック座標を一致させる
[void][RemoteActionNative]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms

$buttonFlags = @{
    left   = @(0x0002, 0x0004)
    right  = @(0x0008, 0x0010)
    middle = @(0x0020, 0x0040)
}

function Write-Log([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $Message"
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
}

function Get-Prop($Obj, [string]$Name, $Default) {
    if ($Obj.PSObject.Properties.Name -contains $Name -and $null -ne $Obj.$Name) {
        return $Obj.$Name
    }
    return $Default
}

function Invoke-Click($A) {
    if ($null -eq (Get-Prop $A 'x' $null) -or $null -eq (Get-Prop $A 'y' $null)) {
        throw 'click には x と y が必要です'
    }
    # x, y は全モニター撮影（mode=All）の画像上の座標。
    # 画像の左上 (0,0) は仮想スクリーンの左上（メインより左・上にモニターがあると負の座標）に当たるので、
    # その分を足して実際の画面座標に変換する。
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $imgX = [int]$A.x
    $imgY = [int]$A.y
    if ($imgX -lt 0 -or $imgY -lt 0 -or $imgX -ge $vs.Width -or $imgY -ge $vs.Height) {
        throw "座標 ($imgX, $imgY) が画像の範囲外です（全モニター画像: $($vs.Width)x$($vs.Height)）"
    }
    $x = $imgX + $vs.X
    $y = $imgY + $vs.Y

    $button = ([string](Get-Prop $A 'button' 'left')).ToLower()
    if (-not $buttonFlags.ContainsKey($button)) {
        throw "button の値が不正です: $button（left / right / middle）"
    }
    $double       = [bool](Get-Prop $A 'double' $false)
    $delayMs      = [int](Get-Prop $A 'delayMs' 0)
    $returnCursor = [bool](Get-Prop $A 'returnCursor' $false)

    if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }

    $original = [System.Windows.Forms.Cursor]::Position

    if (-not [RemoteActionNative]::SetCursorPos($x, $y)) {
        throw 'マウスカーソルの移動に失敗しました'
    }
    Start-Sleep -Milliseconds 50

    $flags = $buttonFlags[$button]
    [RemoteActionNative]::Click($flags[0], $flags[1])
    if ($double) {
        Start-Sleep -Milliseconds 50
        [RemoteActionNative]::Click($flags[0], $flags[1])
    }

    if ($returnCursor) {
        Start-Sleep -Milliseconds 100
        [void][RemoteActionNative]::SetCursorPos($original.X, $original.Y)
    }

    return [ordered]@{ x = $imgX; y = $imgY; screenX = $x; screenY = $y; button = $button; double = $double }
}

# キー名の別名（System.Windows.Forms.Keys の名前に変換する）
$keyAliases = @{
    esc = 'Escape'; backspace = 'Back'; bs = 'Back'; del = 'Delete'; ins = 'Insert'
    ctrl = 'ControlKey'; control = 'ControlKey'; shift = 'ShiftKey'; alt = 'Menu'; win = 'LWin'
    pgup = 'PageUp'; pgdn = 'PageDown'; return = 'Enter'
}
# 拡張キー（正しく動かすために KEYEVENTF_EXTENDEDKEY が必要なキー）
$extendedKeys = @('Insert', 'Delete', 'Home', 'End', 'PageUp', 'PageDown', 'Up', 'Down', 'Left', 'Right', 'LWin', 'RWin')

function Resolve-Key([string]$Name) {
    $n = $Name.Trim()
    if ($keyAliases.ContainsKey($n.ToLower())) { $n = $keyAliases[$n.ToLower()] }
    elseif ($n -match '^[0-9]$') { $n = "D$n" }
    try {
        $k = [System.Windows.Forms.Keys]([Enum]::Parse([System.Windows.Forms.Keys], $n, $true))
    } catch {
        throw "不明なキー名です: '$Name'"
    }
    $name = $k.ToString()
    return [pscustomobject]@{ Vk = [uint16]([int]$k -band 0xFFFF); Extended = ($extendedKeys -contains $name) }
}

# "Ctrl+A" "Shift+Tab" "Enter" のような指定を押して離す
function Invoke-KeyCombo([string]$Combo) {
    $parts = $Combo -split '\+' | Where-Object { $_ -ne '' }
    if ($parts.Count -eq 0) { throw 'キーの指定が空です' }
    $keys = @($parts | ForEach-Object { Resolve-Key $_ })
    try {
        foreach ($k in $keys) {
            [RemoteActionNative]::Key($k.Vk, $false, $k.Extended)
            Start-Sleep -Milliseconds 20
        }
    } finally {
        # 押したキーは逆順で必ず離す（修飾キーが押されたままにならないように）
        for ($i = $keys.Count - 1; $i -ge 0; $i--) {
            [RemoteActionNative]::Key($keys[$i].Vk, $true, $keys[$i].Extended)
            Start-Sleep -Milliseconds 20
        }
    }
}

function Invoke-Type($A) {
    $text = [string](Get-Prop $A 'text' '')
    if ($text -eq '') { throw 'type には text が必要です' }
    $intervalMs = [int](Get-Prop $A 'intervalMs' 10)

    foreach ($c in $text.ToCharArray()) {
        switch ($c) {
            "`r" { continue }
            "`n" { Invoke-KeyCombo 'Enter' }
            "`t" { Invoke-KeyCombo 'Tab' }
            default { [RemoteActionNative]::UnicodeChar($c) }
        }
        if ($intervalMs -gt 0) { Start-Sleep -Milliseconds $intervalMs }
    }
    return [ordered]@{ length = $text.Length }
}

function Save-Result($Result) {
    $tmp = "$resultPath.tmp"
    $Result | ConvertTo-Json -Depth 5 | Out-File -FilePath $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $resultPath -Force
}

$startedAt = Get-Date
$requestId = $null
$steps     = New-Object System.Collections.ArrayList
$allOk     = $true
$topError  = $null

try {
    if (-not (Test-Path $RequestPath)) {
        throw "指示ファイルがありません: $RequestPath"
    }

    $raw = Get-Content -Path $RequestPath -Raw -Encoding UTF8
    # 二重実行を防ぐため、読み込んだらすぐに移動する
    Move-Item -Path $RequestPath -Destination $lastRequestPath -Force

    $request   = $raw | ConvertFrom-Json
    $requestId = Get-Prop $request 'id' $null
    # 全体を @() で囲む（if 式の結果は要素1つの配列が単一の値に展開され、Count が取れなくなるため）
    $actions   = @(if ($request.PSObject.Properties.Name -contains 'actions') { $request.actions } else { $request })

    Write-Log "開始 id=$requestId 操作数=$($actions.Count)"

    foreach ($a in $actions) {
        $name = [string](Get-Prop $a 'action' '')
        $step = [ordered]@{ action = $name; success = $false }
        try {
            switch ($name) {
                'click' {
                    $info = Invoke-Click $a
                    foreach ($k in $info.Keys) { $step[$k] = $info[$k] }
                }
                'type' {
                    $info = Invoke-Type $a
                    foreach ($k in $info.Keys) { $step[$k] = $info[$k] }
                }
                'key' {
                    $combo = [string](Get-Prop $a 'keys' '')
                    Invoke-KeyCombo $combo
                    $step.keys = $combo
                }
                'wait' {
                    $ms = [int](Get-Prop $a 'ms' 1000)
                    Start-Sleep -Milliseconds $ms
                    $step.ms = $ms
                }
                'screenshot' {
                    $mode = [string](Get-Prop $a 'mode' 'All')
                    $file = & $screenshotScript -Mode $mode -OutDir $ScreenshotDir -PassThru
                    $step.file = [string]$file
                }
                default {
                    throw "不明なアクションです: '$name'（click / type / key / wait / screenshot）"
                }
            }
            $step.success = $true
        } catch {
            $step.error = $_.Exception.Message
            $allOk = $false
        }

        [void]$steps.Add([pscustomobject]$step)
        $detail = ($step.GetEnumerator() | Where-Object { $_.Key -ne 'action' } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        Write-Log "  $name $detail"

        # 失敗したら残りの操作は実行しない
        if (-not $step.success) { break }
    }
} catch {
    $topError = $_.Exception.Message
    $allOk = $false
    Write-Log "エラー: $topError"
}

$result = [ordered]@{
    id         = $requestId
    success    = $allOk
    startedAt  = $startedAt.ToString('o')
    finishedAt = (Get-Date).ToString('o')
    error      = $topError
    steps      = @($steps)
}
Save-Result $result
Write-Log "終了 id=$requestId success=$allOk"

if (-not $allOk) { exit 1 }
