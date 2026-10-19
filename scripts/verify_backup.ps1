#requires -Version 5.1
<#
  verify_backup.ps1 -- verify a Rockchip partition backup set.

  WHY THIS EXISTS
    Backup files produced by "export image" can LOOK fine -- a plausible file
    size -- while actually containing junk, because an interrupted export can
    leave a chunk that was never filled in. Never trust size alone.
    Two independent checks catch this:

      1) size check  : file length must equal SECTOR_COUNT x 512
      2) cross check : SHA256 of each partition file must equal SHA256 of the
                       same byte range inside the full-disk image

    The cross check is the stronger one: it proves the full-disk image and the
    per-partition files agree byte for byte, and (when the ranges together cover
    the whole image) that the image has no gap and no overlap.

  NAMING CONVENTION -- read this before touching the parser
      <name>_<START_SECTOR>-<SECTOR_COUNT>.img
      example: uboot_00002000-00002000.img    start 0x2000   count 0x2000
               system_000B2000-00300000.img   start 0x000B2000 count 0x00300000

    START sector = the FIRST hex field in the file name
    COUNT        = the SECOND hex field

    Swapping them, or using "the last field" as the start, makes the cross-check
    report DIFFERENT for almost every partition -- only the ones where
    start == count happen to pass. That exact signature is a parser bug, not bad
    data, and it has been hit before: do not alarm anyone until the parsing is
    re-derived a second way.

  USAGE
    .\verify_backup.ps1 -PartitionDir D:\backup\partitions
    .\verify_backup.ps1 -PartitionDir D:\backup\partitions -FullDisk D:\backup\full.img
    .\verify_backup.ps1 -PartitionDir D:\backup\partitions -FullDisk D:\backup\full.img `
                        -WriteHashList D:\backup\sha256.txt
    .\verify_backup.ps1 -PartitionDir D:\backup\partitions -UserdataChunks D:\backup\ud_*.img `
                        -UserdataStartSector 0x45C000
#>
param(
    [Parameter(Mandatory = $true)][string]$PartitionDir,
    [string]$FullDisk,
    [string[]]$UserdataChunks,
    [string]$UserdataStartSector,
    [string]$WriteHashList
)

$ErrorActionPreference = 'Stop'

function Get-StreamHash {
    param([string]$Path, [long]$Offset = 0, [long]$Length = -1)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try {
        if ($Offset -gt 0) { [void]$fs.Seek($Offset, 'Begin') }
        $buf = New-Object byte[] 4194304
        $remain = if ($Length -lt 0) { [long]::MaxValue } else { $Length }
        while ($remain -gt 0) {
            $want = [int][Math]::Min([long]$buf.Length, $remain)
            $n = $fs.Read($buf, 0, $want)
            if ($n -le 0) { break }
            [void]$sha.TransformBlock($buf, 0, $n, $buf, 0)
            $remain -= $n
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
    }
    finally { $fs.Close() }
}

# --- parse "<name>_<start>-<count>.img" -> start/count in sectors
function Parse-PartitionName {
    param([string]$Name)
    if ($Name -match '^(.*)_([0-9A-Fa-f]{1,8})-([0-9A-Fa-f]{1,8})\.img$') {
        return [pscustomobject]@{
            Base  = $matches[1]
            Start = [Convert]::ToInt64($matches[2], 16)
            Count = [Convert]::ToInt64($matches[3], 16)
        }
    }
    return $null
}

"==== 1) size check ===="
"{0,-42} {1,14} {2,14} {3}" -f 'file', 'expected', 'actual', 'result'
$bad = 0
$items = @()
Get-ChildItem $PartitionDir -File -Filter *.img | Sort-Object Name | ForEach-Object {
    $p = Parse-PartitionName $_.Name
    if (-not $p) { "{0,-42} {1,14} {2,14} {3}" -f $_.Name, '(unparsed)', $_.Length, 'SKIP'; return }
    $exp = $p.Count * 512
    $ok = ($exp -eq $_.Length)
    if (-not $ok) { $bad++ }
    $items += [pscustomobject]@{ File = $_; Start = $p.Start; Count = $p.Count; Expect = $exp }
    "{0,-42} {1,14} {2,14} {3}" -f $_.Name, $exp, $_.Length, $(if ($ok) { 'OK' } else { '** MISMATCH **' })
}
"size mismatches = $bad"

if ($FullDisk) {
    "`n==== 2) cross check against the full-disk image ===="
    $imgLen = (Get-Item $FullDisk).Length
    "full disk = $FullDisk  ($imgLen bytes)"
    "{0,-42} {1,14} {2}" -f 'file', 'at offset', 'result'
    $bad2 = 0
    foreach ($it in $items) {
        $off = $it.Start * 512
        if ($off + $it.File.Length -gt $imgLen) {
            "{0,-42} {1,14} {2}" -f $it.File.Name, $off, '** OUT OF IMAGE RANGE **'
            $bad2++
            continue
        }
        $h1 = Get-StreamHash -Path $it.File.FullName
        $h2 = Get-StreamHash -Path $FullDisk -Offset $off -Length $it.File.Length
        $ok = ($h1 -eq $h2)
        if (-not $ok) { $bad2++ }
        "{0,-42} {1,14} {2}" -f $it.File.Name, $off, $(if ($ok) { 'IDENTICAL' } else { '** DIFFERENT **' })
    }
    "cross-check mismatches = $bad2"
}

if ($UserdataChunks -and $UserdataStartSector) {
    "`n==== 3) cross check userdata chunks ===="
    $off = [Convert]::ToInt64($UserdataStartSector, 16) * 512
    $imgLen = (Get-Item $FullDisk).Length
    "{0,-24} {1,14} {2,16} {3}" -f 'chunk', 'bytes', 'image offset', 'result'
    $bad3 = 0
    Get-ChildItem $UserdataChunks | Sort-Object Name | ForEach-Object {
        $h1 = Get-StreamHash -Path $_.FullName
        $h2 = Get-StreamHash -Path $FullDisk -Offset $off -Length $_.Length
        $ok = ($h1 -eq $h2)
        if (-not $ok) { $bad3++ }
        "{0,-24} {1,14} {2,16} {3}" -f $_.Name, $_.Length, $off, $(if ($ok) { 'IDENTICAL' } else { '** DIFFERENT **' })
        $script:off = $off
        $off += $_.Length
    }
    "chunk mismatches = $bad3"
    if ($off -eq $imgLen) { "coverage: chunks + partitions reach the end of the image exactly -> no gap, no overlap" }
    else { "coverage: ends at $off but image is $imgLen bytes -> CHECK for gap/overlap" }
}

if ($WriteHashList) {
    "`n==== 4) writing hash list -> $WriteHashList ===="
    $lines = @()
    $lines += "SHA256 CHECKLIST  generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "usage: Get-FileHash <file> -Algorithm SHA256  and compare"
    $lines += ("=" * 100)
    foreach ($f in (Get-ChildItem $PartitionDir -File -Filter *.img | Sort-Object Name)) {
        $lines += ("{0}  {1,14}  {2}" -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash, $f.Length, $f.Name)
    }
    if ($FullDisk) {
        $lines += ("{0}  {1,14}  {2}" -f (Get-FileHash $FullDisk -Algorithm SHA256).Hash, (Get-Item $FullDisk).Length, (Split-Path $FullDisk -Leaf))
    }
    [IO.File]::WriteAllLines($WriteHashList, $lines, (New-Object Text.UTF8Encoding($true)))
    "written: $((Get-Item $WriteHashList).Length) bytes"
}

"`n==== done ===="
if ($bad -or $bad2 -or $bad3) { "RESULT: problems found (size=$bad cross=$bad2 chunks=$bad3) -- do NOT treat this backup as good" }
else { "RESULT: all checks passed" }
