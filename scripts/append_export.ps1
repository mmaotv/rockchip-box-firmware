#requires -Version 5.1
<#
  append_export.ps1 -- dump a huge flash region into ONE file without needing 2x space.

  WHY
    "export image" writes each segment to <tool>\Output\ExportImage.img and then
    moves it. Dumping a 30 GB region in 1 GB pieces the naive way therefore needs
    the pieces AND the joined file at the same time - 60 GB - which does not fit
    on a disk holding only the archive. This script exports ONE chunk, appends it
    to the target, deletes the chunk, and only then starts the next one, so peak
    usage is (target + 1 chunk).

    Progress is kept in <Target>.progress as one line per finished chunk, so an
    interrupted run resumes where it stopped. Sizes are checked against
    sector_count * 512 on every chunk - a right-sized file can still be junk, so
    the joined result must afterwards be cross-checked against another capture.

  USAGE
    .\append_export.ps1 -Spec chunks.txt -Target D:\...\super_001E1000-00614000.img
    .\append_export.ps1 -Spec chunks.txt -Target ... -ChunkDir D:\...\tmp

  SPEC
    <start_sector>,<count_sectors>       hex (0x..) or decimal; '#' = comment
    The chunk list must describe the whole region, in order.
#>
param(
    [Parameter(Mandatory = $true)][string]$Spec,
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$ChunkDir = '',
    [string]$RkTool = 'C:\Users\Administrator\.codebuddy\skills\rockchip-box-firmware\scripts\rk_tool.ps1',
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RkTool)) { throw "rk_tool.ps1 not found: $RkTool" }
if (-not $ChunkDir) { $ChunkDir = Join-Path (Split-Path $Target -Parent) '_chunks' }
New-Item -ItemType Directory -Force -Path $ChunkDir | Out-Null

# ---- parse the spec -------------------------------------------------------
$chunks = @()
foreach ($line in (Get-Content $Spec | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' })) {
    $f = $line.Split(',')
    if ($f.Count -lt 2) { throw "bad spec line: $line" }
    $chunks += [pscustomobject]@{
        Start = [int64]$f[0].Trim()
        Count = [int64]$f[1].Trim()
    }
}
$totalBytes = 0L
foreach ($c in $chunks) { $totalBytes += $c.Count * 512 }
"spec: $($chunks.Count) chunks, $([math]::Round($totalBytes / 1GB, 2)) GiB -> $Target"

# ---- resume bookkeeping ---------------------------------------------------
$progress = "$Target.progress"
$done = 0
if ((Test-Path $progress) -and (Test-Path $Target)) {
    $done = @(Get-Content $progress | Where-Object { $_ -match '\S' }).Count
}
$expectSize = 0L
for ($i = 0; $i -lt $done; $i++) { $expectSize += $chunks[$i].Count * 512 }
if ($done -gt 0) {
    $actual = (Get-Item $Target).Length
    if ($actual -ne $expectSize) {
        throw "target is $actual bytes but $done finished chunks account for $expectSize - delete one of them and retry"
    }
    "resuming: $done/$($chunks.Count) chunks already appended"
}

$dstStream = [IO.File]::Open($Target, 'Append', 'Write')
try {
    for ($i = $done; $i -lt $chunks.Count; $i++) {
        $c = $chunks[$i]
        $expect = $c.Count * 512
        $chunkFile = Join-Path $ChunkDir ('chunk_{0:D3}.img' -f $i)
        if (Test-Path $chunkFile) { Remove-Item $chunkFile -Force }

        $ok = $false
        for ($try = 1; $try -le $MaxAttempts -and -not $ok; $try++) {
            $stamp = Get-Date -Format 'HH:mm:ss'
            "$stamp [$($i + 1)/$($chunks.Count)] start=0x$('{0:X}' -f $c.Start) count=$($c.Count) attempt $try"
            & $RkTool export $c.Start $c.Count $chunkFile | ForEach-Object { "   $_" }
            if ((Test-Path $chunkFile) -and (Get-Item $chunkFile).Length -eq $expect) {
                $ok = $true
            }
            else {
                $got = if (Test-Path $chunkFile) { (Get-Item $chunkFile).Length } else { -1 }
                "   BAD size=$got expect=$expect"
                if (Test-Path $chunkFile) { Remove-Item $chunkFile -Force }
                Start-Sleep -Seconds 3
            }
        }
        if (-not $ok) { throw "giving up on chunk $i after $MaxAttempts attempts" }

        $src = [IO.File]::OpenRead($chunkFile)
        try { $src.CopyTo($dstStream, 4194304) } finally { $src.Close() }
        $dstStream.Flush()
        Remove-Item $chunkFile -Force
        Add-Content -Path $progress -Value ("{0},{1} {2}" -f $c.Start, $c.Count, (Get-Date -Format 'HH:mm:ss'))
        "$(Get-Date -Format 'HH:mm:ss')   appended, target now $((Get-Item $Target).Length) bytes"
    }
}
finally { $dstStream.Close() }

$final = (Get-Item $Target).Length
"done: $Target  $final bytes  (expected $totalBytes)"
if ($final -ne $totalBytes) { "SIZE MISMATCH - do not trust this file" } else { "size check OK" }
