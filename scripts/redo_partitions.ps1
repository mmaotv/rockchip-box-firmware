#requires -Version 5.1
# Re-dump the partitions that were captured before the read guard was understood.
# Flow: (device must be in LOADER mode) -> 进入Maskrom -> 下载 patched loader ->
#       two parity-shifted exports per partition -> block merge -> install.
# ASCII only on purpose: this file is invoked with powershell -File.
$ErrorActionPreference = 'Continue'
$S = 'C:\Users\Administrator\.codebuddy\skills\rockchip-box-firmware\scripts\rk_tool.ps1'
$W = 'd:\APPDEV\zhushouAPP\_rk_backup\work'
$DEST = 'd:\APPDEV\zhushouAPP\_rk_backup\newdev32g\01_备份镜像\partitions'
$LOADER = 'd:\APPDEV\zhushouAPP\_rk_backup\rkbin\rk3328_loader_v1.22.250_no32Mguard.bin'
$MERGE = "$W\merge_two.py"

$parts = @(
    @{ n = 'boot';          s = 0xC800;   c = 0x14000 },
    @{ n = 'recovery';      s = 0x20800;  c = 0x30000 },
    @{ n = 'backup';        s = 0x50800;  c = 0xC0000 },
    @{ n = 'metadata';      s = 0x1D0800; c = 0x8000 },
    @{ n = 'baseparameter'; s = 0x1D8800; c = 0x800 },
    @{ n = 'logo';          s = 0x1D9000; c = 0x8000 }
)

function Status { (& $S text 1004) }
function PnpId {
    $d = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like '*VID_2207*' } | Select-Object -First 1
    if ($d) { return $d.InstanceId } else { return '(none)' }
}

"== 0) device state =="
"   status: " + (Status)
"   pnp   : " + (PnpId)
if ((Status) -notmatch 'LOADER') {
    "ABORT: 设备不在 LOADER 模式。请先把盒子切到 LOADER 模式再运行本脚本："
    "   方法一（推荐）：盒子断电，按住复位/恢复小孔不放，再上电，3-5 秒后松手；"
    "   方法二：在盒子上打开网络调试后告诉我，我用 adb reboot loader 切。"
    return
}

"== 1) 进入 Maskrom，并确认 ROM 重新掌权（PnP 序列号消失） =="
& $S click 1050
$ok = $false
for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Seconds 3
    $id = PnpId
    "   t={0,3}s  status={1}  pnp={2}" -f ($i * 3), (Status), $id
    if ($id -ne '(none)' -and $id -match [regex]::Escape('&0&2')) { $ok = $true; break }
}
if (-not $ok) { "   警告：没看到'序列号消失'的状态，仍继续尝试下载" }

"== 2) 下载 patched loader =="
& $S settext 1025 $LOADER
Start-Sleep -Milliseconds 400
& $S click 1027
$ok2 = $false
for ($i = 1; $i -le 15; $i++) {
    Start-Sleep -Seconds 3
    $id = PnpId
    "   t={0,3}s  status={1}  pnp={2}" -f ($i * 3), (Status), $id
    if ($i -ge 2 -and $id -notmatch [regex]::Escape('&0&2')) { $ok2 = $true; break }
}
if (-not $ok2) { "   警告：没看到 loader 起来（序列号回来），后续读取可能仍是填充" }

"== 3) 逐分区两遍导出 + 合并 =="
foreach ($p in $parts) {
    $name = $p.n; $start = $p.s; $cnt = $p.c
    $a = "$W\$($name)_A.bin"
    $b = "$W\$($name)_B.bin"
    $out = "$DEST\$('{0}_{1:X8}-{2:X8}.img' -f $name, $start, $cnt)"
    "--- $name  start=0x$('{0:X}' -f $start)  count=0x$('{0:X}' -f $cnt)  ($([math]::Round($cnt*512/1MB,1)) MB)"
    Remove-Item $a, $b -Force -ErrorAction SilentlyContinue
    & $S export $start ($cnt + 256) $a
    & $S export ($start - 128) ($cnt + 512) $b
    if (-not (Test-Path $a) -or -not (Test-Path $b)) { "   !! 导出缺失，跳过"; continue }
    python -X utf8 $MERGE $a $b $out $cnt
    Remove-Item $a, $b -Force -ErrorAction SilentlyContinue
}

"== 4) 结果清单 =="
Get-ChildItem $DEST -File | Sort-Object Name | Select-Object Name, Length |
    Format-Table -AutoSize
