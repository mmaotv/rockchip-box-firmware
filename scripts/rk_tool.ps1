#requires -Version 5.1
<#
  RKDevTool automation driver (ASCII only on purpose).

  Controls are addressed by their OWN control id (GetDlgCtrlID), never by screen
  coordinates, so destructive buttons (erase-all / erase-sector / clear-serial)
  can never be hit by accident.

  Key findings this script is built on:
    * The tool's Log\Log<date>.txt only records ERROR lines. A successful
      "test device" / "read flash info" / "export image" writes NOTHING to it.
    * The export writes progressively (size grows), and during the operation the
      "export image" button (id 1033) is DISABLED; it is re-enabled when done.
      That enabled/disabled transition is the reliable completion signal.
    * The "start sector" (1035) and "sector count" (1039) edits really are used,
      in DECIMAL. They are filled with WM_SETTEXT.

  Usage:
    .\rk.ps1 dump
    .\rk.ps1 text <id> | click <id> | settext <id> <v> | show <id> <0|1>
    .\rk.ps1 log [n] | dialogs | ok
    .\rk.ps1 observe <startLba> <sectorCount>
    .\rk.ps1 export <startLba> <sectorCount> <destFile>
    .\rk.ps1 plan <specFile>
    .\rk.ps1 dlgset <id> <text>      set an Edit inside a visible dialog (file pickers)
    .\rk.ps1 listbox <id>            list a ListBox's items (LB_GETCOUNT/LB_GETTEXT)
#>
param(
    [Parameter(Position = 0)][string]$Action = 'dump',
    [Parameter(Position = 1)][string]$A1,
    [Parameter(Position = 2)][string]$A2,
    [Parameter(Position = 3)][string]$A3
)

$ErrorActionPreference = 'Stop'

# resolve the running tool (AndroidTool v2.x or RKDevTool v3.x) and its folder
$script:ToolProc = $null
function Get-ToolProc {
    if ($script:ToolProc) { return $script:ToolProc }
    foreach ($n in @('RKDevTool', 'AndroidTool')) {
        $p = Get-Process $n -ErrorAction SilentlyContinue
        if ($p) { $script:ToolProc = $p[0]; return $script:ToolProc }
    }
    throw 'no Rockchip tool running (AndroidTool or RKDevTool)'
}
$TOOL_DIR = Split-Path (Get-ToolProc).Path -Parent
if (-not (Test-Path $TOOL_DIR)) { throw 'tool folder not found' }

$OUT_IMG  = Join-Path $TOOL_DIR 'Output\ExportImage.img'
$LOG_FILE = Join-Path $TOOL_DIR ('Log\Log{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd'))

$ID_START = 1035
$ID_COUNT = 1039
$ID_EXPORT = 1033
$ID_STATUS = 1004
$ID_WRITEADDR = 1062

if (-not ('Rk32' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Rk32 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")]
    public static extern IntPtr SendStr(IntPtr hWnd, uint msg, IntPtr wp, string lp);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")]
    public static extern IntPtr SendBuf(IntPtr hWnd, uint msg, IntPtr wp, StringBuilder lp);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", EntryPoint="SendMessageW")]
    public static extern IntPtr SendMsg(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp);
}
'@
}

function Get-MainHwnd {
    $p = Get-ToolProc
    # MainWindowHandle is NOT reliable: after a click the tool owns a small
    # "ZTitleTip" popup and .NET can pick that as the process main window, which
    # has no controls at all (every id then "not found"). Prefer the real frame:
    # a top-level #32770 whose title carries the tool name/version.
    $script:tpid = $p.Id
    $script:frameHwnd = [IntPtr]::Zero
    $cb = [Rk32+EnumProc]{
        param([IntPtr]$h, [IntPtr]$l)
        $pid2 = 0
        [void][Rk32]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pid2 -ne $script:tpid) { return $true }
        $cn = New-Object System.Text.StringBuilder 64
        [void][Rk32]::GetClassName($h, $cn, 64)
        if ($cn.ToString() -ne '#32770') { return $true }
        $tx = New-Object System.Text.StringBuilder 160
        [void][Rk32]::GetWindowText($h, $tx, 160)
        if ($tx.ToString() -match 'v3\.|v2\.|AndroidTool') { $script:frameHwnd = $h; return $false }
        return $true
    }
    [void][Rk32]::EnumWindows($cb, [IntPtr]::Zero)
    $h = $script:frameHwnd
    if ($h -eq [IntPtr]::Zero) { $h = [IntPtr]$p.MainWindowHandle }
    if ($h -eq [IntPtr]::Zero -or -not [Rk32]::IsWindow($h)) { throw 'main window handle not available' }
    return $h
}

function Get-CtrlMap {
    $map = @{}
    $rows = New-Object System.Collections.ArrayList
    $main = Get-MainHwnd
    $cb = [Rk32+EnumProc]{
        param([IntPtr]$h, [IntPtr]$l)
        $id = [Rk32]::GetDlgCtrlID($h)
        if ($id -gt 0 -and -not $map.ContainsKey($id)) {
            $map[$id] = $h
            $ts = New-Object System.Text.StringBuilder 512
            [void][Rk32]::GetWindowText($h, $ts, 512)
            $cs = New-Object System.Text.StringBuilder 128
            [void][Rk32]::GetClassName($h, $cs, 128)
            [void]$rows.Add([pscustomobject]@{
                Id = $id; Hwnd = $h; Class = $cs.ToString(); Text = $ts.ToString()
                Vis = [Rk32]::IsWindowVisible($h); Ena = [Rk32]::IsWindowEnabled($h)
            })
        }
        return $true
    }
    [void][Rk32]::EnumChildWindows($main, $cb, [IntPtr]::Zero)
    return @{ Map = $map; Rows = $rows }
}

function Get-Ctrl([int]$id) {
    $m = Get-CtrlMap
    if (-not $m.Map.ContainsKey($id)) { throw "control id $id not found" }
    return $m.Map[$id]
}

function Write-CtrlText([int]$id, [string]$v) {
    $h = Get-Ctrl $id
    [void][Rk32]::SendStr($h, 0x000C, [IntPtr]::Zero, $v)
    return $h
}

function Invoke-CtrlClick([int]$id) {
    $h = Get-Ctrl $id
    if (-not [Rk32]::IsWindowEnabled($h)) { throw "control $id is disabled" }
    [void][Rk32]::PostMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
    return $h
}

function Get-LogTail([int]$n = 15) {
    if (-not (Test-Path $LOG_FILE)) { return @() }
    return @(Get-Content $LOG_FILE -Tail $n -ErrorAction SilentlyContinue)
}

function Get-LogSince([int64]$len) {
    if (-not (Test-Path $LOG_FILE)) { return @() }
    $fs = [IO.File]::Open($LOG_FILE, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -le $len) { return @() }
        [void]$fs.Seek($len, 'Begin')
        $sr = New-Object IO.StreamReader($fs)
        $t = $sr.ReadToEnd()
        return @($t -split "`r?`n" | Where-Object { $_ -ne '' })
    } finally { $fs.Close() }
}

function Get-TopWindows {
    $rows = New-Object System.Collections.ArrayList
    $mypid = (Get-ToolProc).Id
    $cb = [Rk32+EnumProc]{
        param([IntPtr]$h, [IntPtr]$l)
        $op = 0
        [void][Rk32]::GetWindowThreadProcessId($h, [ref]$op)
        if ($op -eq $mypid) {
            $ts = New-Object System.Text.StringBuilder 256
            [void][Rk32]::GetWindowText($h, $ts, 256)
            $cs = New-Object System.Text.StringBuilder 128
            [void][Rk32]::GetClassName($h, $cs, 128)
            [void]$rows.Add([pscustomobject]@{ Hwnd = $h; Class = $cs.ToString(); Title = $ts.ToString(); Vis = [Rk32]::IsWindowVisible($h) })
        }
        return $true
    }
    [void][Rk32]::EnumWindows($cb, [IntPtr]::Zero)
    return $rows
}

function Get-ChildCtrls([IntPtr]$parent) {
    $rows = New-Object System.Collections.ArrayList
    $cb = [Rk32+EnumProc]{
        param([IntPtr]$h, [IntPtr]$l)
        $ts = New-Object System.Text.StringBuilder 256
        [void][Rk32]::GetWindowText($h, $ts, 256)
        $cs = New-Object System.Text.StringBuilder 128
        [void][Rk32]::GetClassName($h, $cs, 128)
        [void]$rows.Add([pscustomobject]@{ Id = [Rk32]::GetDlgCtrlID($h); Hwnd = $h; Class = $cs.ToString(); Text = $ts.ToString(); Ena = [Rk32]::IsWindowEnabled($h) })
        return $true
    }
    [void][Rk32]::EnumChildWindows($parent, $cb, [IntPtr]::Zero)
    return $rows
}

function Close-ModalDialogs([IntPtr]$main) {
    # Returns the number of modal dialogs currently up.
    # SAFETY: only a dialog with EXACTLY ONE button is dismissed (pure info box).
    # A dialog with 2+ buttons could be a confirmation prompt, so it is left
    # untouched - the caller then aborts the segment instead of guessing.
    $diag = Join-Path $TOOL_DIR 'rk_diag.log'
    $seen = 0
    foreach ($w in (Get-TopWindows)) {
        if ($w.Hwnd -eq $main -or -not $w.Vis) { continue }
        if ($w.Class -ne '#32770') { continue }
        $seen++
        $kids = @(Get-ChildCtrls $w.Hwnd)
        $btns = @($kids | Where-Object { $_.Class -eq 'Button' -and $_.Ena })
        $text = (($kids | Where-Object { $_.Class -eq 'Static' } | ForEach-Object { $_.Text }) -join ' / ')
        "$(Get-Date -Format 'HH:mm:ss') dialog title=[$($w.Title)] buttons=$($btns.Count) text=[$text]" |
            Out-File -FilePath $diag -Append -Encoding UTF8
        if ($btns.Count -eq 1) {
            [void][Rk32]::PostMessage($btns[0].Hwnd, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    }
    return $seen
}

function Invoke-SegmentExport([string]$lba, [int64]$cnt, [string]$dest) {
    $expect  = $cnt * 512
    $logLen0 = if (Test-Path $LOG_FILE) { (Get-Item $LOG_FILE).Length } else { 0 }
    if (Test-Path $OUT_IMG) { Remove-Item $OUT_IMG -Force }

    $main = Get-MainHwnd
    $btn  = Get-Ctrl $ID_EXPORT

    [void](Write-CtrlText $ID_START $lba)
    [void](Write-CtrlText $ID_COUNT $cnt.ToString())
    Start-Sleep -Milliseconds 400
    [void](Invoke-CtrlClick $ID_EXPORT)

    $sawDisabled = $false
    $lastSize = -1
    $stable = 0
    $t0 = Get-Date
    while ($true) {
        Start-Sleep -Seconds 2
        $el = ((Get-Date) - $t0).TotalSeconds

        if ((Close-ModalDialogs $main) -gt 0) { Start-Sleep -Seconds 1; break }

        $ena = [Rk32]::IsWindowEnabled($btn)
        if (-not $ena) { $sawDisabled = $true }

        $size = if (Test-Path $OUT_IMG) { (Get-Item $OUT_IMG).Length } else { -1 }
        if ($size -eq $lastSize) { $stable++ } else { $stable = 0; $lastSize = $size }

        if ($sawDisabled -and $ena) { break }
        if (-not $sawDisabled -and $el -gt 25 -and $size -ge $expect -and $stable -ge 2) { break }
        if ($el -gt 3600) { break }
    }

    $bad = @(Get-LogSince $logLen0 | Where-Object { $_ -match 'ExportImageProc' -or $_ -match 'ReadComData failed' })

    if (-not (Test-Path $OUT_IMG)) { throw 'no output file produced' }
    if ($dest) { Move-Item $OUT_IMG $dest -Force; $f = $dest } else { $f = $OUT_IMG }
    return [pscustomobject]@{
        Ok = ($bad.Count -eq 0); Err = ($bad -join ' | '); Dest = $f
        Size = (Get-Item $f).Length; Expect = $expect
    }
}

# ---------------- actions ----------------
switch ($Action.ToLower()) {

    'dump' {
        $m = Get-CtrlMap
        "descendants=$($m.Rows.Count)"
        $m.Rows | Sort-Object Id | ForEach-Object {
            '{0,5} {1,-18} vis={2,-5} ena={3,-5} "{4}"' -f $_.Id, $_.Class, $_.Vis, $_.Ena, $_.Text
        }
    }

    'text' { $h = Get-Ctrl ([int]$A1); $sb = New-Object System.Text.StringBuilder 1024; [void][Rk32]::GetWindowText($h, $sb, 1024); $sb.ToString() }
    'click' { [void](Invoke-CtrlClick ([int]$A1)); "clicked $A1" }
    'settext' { [void](Write-CtrlText ([int]$A1) ([string]$A2)); "set $A1 = $A2" }
    'show' { $h = Get-Ctrl ([int]$A1); [void][Rk32]::ShowWindow($h, [int]$A2); "show $A1 = $A2" }
    'log' { $n = if ($A1) { [int]$A1 } else { 15 }; Get-LogTail $n }

    'dialogs' {
        $main = Get-MainHwnd
        foreach ($w in (Get-TopWindows)) {
            'top {0} cls={1} vis={2} title="{3}"' -f $w.Hwnd, $w.Class, $w.Vis, $w.Title
            if ($w.Hwnd -ne $main) {
                foreach ($c in (Get-ChildCtrls $w.Hwnd)) {
                    '        {0,5} {1,-12} ena={2,-5} "{3}"' -f $c.Id, $c.Class, $c.Ena, $c.Text
                }
            }
        }
    }

    'ok' { $main = Get-MainHwnd; $n = Close-ModalDialogs $main; "closed $n dialog button(s)" }

    'observe' {
        $lba = [string]$A1
        $cnt = [int64]$A2
        $expect = $cnt * 512
        $len0 = if (Test-Path $LOG_FILE) { (Get-Item $LOG_FILE).Length } else { 0 }
        [void](Write-CtrlText $ID_START $lba)
        [void](Write-CtrlText $ID_COUNT $cnt.ToString())
        Start-Sleep -Milliseconds 500
        if (Test-Path $OUT_IMG) { Remove-Item $OUT_IMG -Force }
        [void](Invoke-CtrlClick $ID_EXPORT)
        $t0 = Get-Date
        for ($i = 1; $i -le 60; $i++) {
            Start-Sleep -Seconds 2
            $el = [int]((Get-Date) - $t0).TotalSeconds
            $size = if (Test-Path $OUT_IMG) { (Get-Item $OUT_IMG).Length } else { -1 }
            $ena = [Rk32]::IsWindowEnabled((Get-Ctrl $ID_EXPORT))
            $new = Get-LogSince $len0
            $len0 = if (Test-Path $LOG_FILE) { (Get-Item $LOG_FILE).Length } else { $len0 }
            't={0,4}s size={1,12} btnEnabled={2}' -f $el, $size, $ena
            $new | ForEach-Object { '      LOG> ' + $_ }
            if ($i -gt 3 -and $ena -and $size -ge $expect) { break }
        }
    }

    'export' {
        $r = Invoke-SegmentExport ([string]$A1) ([int64]$A2) ([string]$A3)
        if ($r.Ok) { "DONE  $($r.Dest)  $($r.Size) bytes (expect $($r.Expect))" }
        else { "FAIL  $($r.Dest)  $($r.Size) bytes (expect $($r.Expect))  ERR: $($r.Err)" }
    }

    'plan' {
        $spec = [string]$A1
        $prog = "$spec.progress"
        $lines = @(Get-Content $spec | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' })
        $i = 0
        foreach ($ln in $lines) {
            $i++
            $f = $ln.Split(',')
            $start = $f[0].Trim()
            $cnt = [int64]$f[1].Trim()
            $dest = $f[2].Trim()
            $stamp = Get-Date -Format 'HH:mm:ss'
            "$stamp [$i/$($lines.Count)] start=$start count=$cnt -> $dest" | Tee-Object -FilePath $prog -Append

            if ((Test-Path $dest) -and (Get-Item $dest).Length -eq ($cnt * 512)) {
                "$(Get-Date -Format 'HH:mm:ss')   skip already complete" | Tee-Object -FilePath $prog -Append
                continue
            }

            $attempt = 0
            while ($true) {
                $attempt++
                try {
                    $r = Invoke-SegmentExport $start $cnt $dest
                    if ($r.Ok -and $r.Size -eq $r.Expect) {
                        "$(Get-Date -Format 'HH:mm:ss')   OK $($r.Size) bytes" | Tee-Object -FilePath $prog -Append
                        break
                    }
                    "$(Get-Date -Format 'HH:mm:ss')   BAD size=$($r.Size) expect=$($r.Expect) err=$($r.Err)" | Tee-Object -FilePath $prog -Append
                } catch {
                    "$(Get-Date -Format 'HH:mm:ss')   EXC $($_.Exception.Message)" | Tee-Object -FilePath $prog -Append
                }
                if ($attempt -ge 3) {
                    "$(Get-Date -Format 'HH:mm:ss')   GIVE UP on this segment" | Tee-Object -FilePath $prog -Append
                    break
                }
                Start-Sleep -Seconds 3
            }
        }
        "$(Get-Date -Format 'HH:mm:ss') PLAN FINISHED" | Tee-Object -FilePath $prog -Append
    }

    'dlgclick' {
        # Click a button by control id inside a visible top-level dialog.
        $main = Get-MainHwnd
        $want = [int]$A1
        $hit = 0
        foreach ($w in (Get-TopWindows)) {
            if ($w.Hwnd -eq $main -or -not $w.Vis) { continue }
            if ($w.Class -ne '#32770') { continue }
            foreach ($c in (Get-ChildCtrls $w.Hwnd)) {
                if ($c.Class -eq 'Button' -and $c.Id -eq $want) {
                    [void][Rk32]::PostMessage($c.Hwnd, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
                    "clicked id=$want [$($c.Text)] on dialog [$($w.Title)]"
                    $hit++
                }
            }
        }
        if ($hit -eq 0) { "no button id=$want in any dialog" }
    }

    'dlgtext' {
        $main = Get-MainHwnd
        foreach ($w in (Get-TopWindows)) {
            if ($w.Hwnd -eq $main -or -not $w.Vis) { continue }
            foreach ($c in (Get-ChildCtrls $w.Hwnd)) {
                'dlg {0} [{1}] {2,5} {3,-10} "{4}"' -f $w.Hwnd, $w.Title, $c.Id, $c.Class, $c.Text
            }
        }
    }

    'dlgset' {
        # Set the text of an Edit control inside a visible dialog. Used on the
        # standard file pickers the tool opens (id 1148 = the "file name" box).
        $main = Get-MainHwnd
        $want = [int]$A1
        $text = [string]$A2
        $hit = 0
        foreach ($w in (Get-TopWindows)) {
            if ($w.Hwnd -eq $main -or -not $w.Vis) { continue }
            if ($w.Class -ne '#32770') { continue }
            foreach ($c in (Get-ChildCtrls $w.Hwnd)) {
                if ($c.Id -eq $want -and $c.Class -eq 'Edit') {
                    [void][Rk32]::SendStr($c.Hwnd, 0x000C, [IntPtr]::Zero, $text)
                    "set id=$want = $text on dialog [$($w.Title)]"
                    $hit++
                }
            }
        }
        if ($hit -eq 0) { "no Edit with id=$want in any dialog" }
    }

    'listbox' {
        # Read a ListBox's items: LB_GETCOUNT 0x018B, LB_GETTEXT 0x0189.
        $h = Get-Ctrl ([int]$A1)
        $r = [Rk32]::SendMsg($h, 0x018B, [IntPtr]::Zero, [IntPtr]::Zero)
        $n = [int]$r.ToInt64()
        "items=$n"
        for ($i = 0; $i -lt $n; $i++) {
            $sb = New-Object System.Text.StringBuilder 512
            [void][Rk32]::SendBuf($h, 0x0189, [IntPtr]$i, $sb)
            "  [$i] $($sb.ToString())"
        }
    }

    'findmax' {
        # Binary search the last LBA that can be fully read (128-sector probe).
        # Works because the device's loader rejects out-of-range reads, and the
        # tool surfaces that as an incomplete/erroring export.
        $hi = if ($A1) { [int64]$A1 } else { 0x2000000 }   # default 33,554,432 sectors (16 GiB)
        $out = Join-Path $TOOL_DIR 'probe.tmp'
        $probe = {
            param([int64]$lba)
            try {
                $r = Invoke-SegmentExport $lba.ToString() 128 $out
                return ($r.Ok -and $r.Size -eq $r.Expect)
            } catch { return $false }
        }

        # make sure the upper bound really is unreachable
        $i = 0
        while ((& $probe $hi) -and $hi -lt 0x40000000 -and $i -lt 4) {
            $hi = $hi * 2
            $i++
            "top bound $hi is still readable, doubling"
        }
        "upper bound $hi is not fully readable -> starting binary search"

        $lo = 0L
        $guard = 0
        while ((($hi - $lo) -gt 1) -and $guard -lt 60) {
            $guard++
            $mid = [int64](($lo + $hi) / 2)
            $ok = & $probe $mid
            "$(Get-Date -Format 'HH:mm:ss') probe lba=$mid readable=$ok   (lo=$lo hi=$hi)"
            if ($ok) { $lo = $mid } else { $hi = $mid }
        }
        $total = $lo + 128
        "MAX_READABLE_LBA=$lo"
        "TOTAL_SECTORS=$total"
        "TOTAL_BYTES=$($total * 512)"
        "TOTAL_GIB=$([math]::Round($total * 512 / 1GB, 3))"
        if (Test-Path $out) { Remove-Item $out -Force }
    }

    default { 'unknown action' }
}
