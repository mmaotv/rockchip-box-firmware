#requires -Version 5.1
<#
  build_firmware.ps1 -- pack partitions into a flashable Rockchip update.img.

  TWO STEPS, two Rockchip tools, and the loader is where everybody fails:

      AFPTool      -pack  <packDir> <out.rkaf>            builds the RKAF container
      RKImageMaker -RK33  <loader> <rkaf> <out.img> -os_type:ANDROIDOS
                                                          wraps it into the RKFW image

  *** THE ONE THING THAT MATTERS: <loader> must be a COMBINED container ***
      A firmware loader is NOT a single rkbin component. It is a container that
      embeds all three parts (DDR init + SPL/FlashBoot + usbplug). Feeding a
      single component produces a package that fails on import with:

          RKDevTool v3.x : "firmware import failed -- loader digest check failed"
                           Log: Error:Loading loader failed,err=-9
          AndroidTool    : "loading firmware failed"
                           Log: Error:Loading firmware failed,err=-2009
          (the exact Chinese wording of these two prompts, and every other
           error string, is in references/firmware-package-format.md section 6
           -- scripts stay ASCII-only on purpose, see pitfalls.md trap 5)

      Known-good containers and their magics:
          RK3368 / RK330A : 219,470 bytes, magic "BOOT"   (RK3368MiniLoaderAll_V2.30.bin)
          RK356x          : built by boot_merger from RKBOOT/RK356xMINIALL.ini
      Single components that MUST NOT be passed (all fail):
          rk3368_miniloader_v2.58.bin   117,700  "RSAK" single component
          rk3368_usbplug_v2.58.bin       82,692  "RSAK" single component
          rk3368_ddr_600MHz_v2.06.bin    18,972  "RK33:" single component
          the device's own uboot image  4,194,304 "LOADER  " -- wrong container

      HOW TO GET A GOOD ONE FOR A NEW DEVICE (most reliable order):
        a) Extract it from a factory update.img of the SAME model. The loader
           sits right after the 102-byte RKFW header:
              offset 102, length = u32 LE at offset 29
           A 2017-era RK3368 factory package yields the 219,470-byte "BOOT"
           container this way -- verified, and it is what unblocked this task.
        b) Build one with rockchip's own boot_merger + the recipe in
           rkbin/RKBOOT/<CHIP>MINIALL.ini :
              cd <rkbin>; ./tools/boot_merger RKBOOT/RK3368MINIALL.ini
           (the ini names exact component paths and the output file name)

  *** ACCEPTANCE CRITERIA -- checkable WITHOUT a device ***
      Read the produced image's RKFW header and assert all of:
          u16 @ 4  == 102                  (header length)
          u32 @ 29 == <loader length>      (loader size field)
          u32 @ 33 == 102 + loader length  (image offset field)
      and, when a known-good package exists, that the loader region is
      SHA256-identical to the known-good loader:
          SHA256(image[102 .. 102+loaderLen)) == SHA256(known good loader)
      For the RK3368 factory loader the hash observed in this project is
          9987D7A2F15EE0646650AEBD953ED3DE8BD2608E56AA0F975CD873ADB4CE3688
      Note it is the loader region only (offset 102, 219,470 bytes), not the
      whole package. Recompute it against your own known-good package before
      trusting it; hashes must never be carried over between devices.
      Wrong packages are obvious: loader_size 4,194,304 or 117,700.

  *** TOOLCHAIN MATCHING ***
      Build with the same tool generation you will flash with, and be
      consistent between AFPTool and RKImageMaker:
          AndroidTool v2.84 era : AFPTool v1.65 + RKImageMaker ver 1.67
          RKDevTool  v3.37 era  : AFPTool v2.28 + RKImageMaker ver 2.23
      Both generations have shipped working packages; do not mix a 2024
      RKAF builder with a 2021 wrapper.

  *** SIZE LIMIT ***
      These tools are 32-bit. Keep update.img comfortably below 2 GB
      (a 1.72 GB package was flashed fine). To test cheaply, first build a
      SMALL package that omits the system partition: the import check fires
      before any content is read, so a small package validates the loader
      just as well as a full one, in seconds instead of minutes.

  USAGE
    # -ToolBin defaults to the bundled modern toolchain:
    #   <repo>/tools/RKDevTool_v3.37/bin  (AFPTool v2.28 + RKImageMaker v2.23)
    # For legacy RK3368/RK330A boxes, pass the legacy toolchain instead:
    .\build_firmware.ps1 -PackDir D:\b\pack -Loader D:\b\loader.bin -OutFile D:\b\update.img
    .\build_firmware.ps1 -PackDir D:\b\pack -Loader D:\b\loader.bin -OutFile D:\b\update.img `
                         -ToolBin '..\tools\AndroidTool_v2.84\bin'
    .\build_firmware.ps1 ... -KeepRkaf          (keep the intermediate .rkaf)
    .\build_firmware.ps1 ... -ReferenceLoader D:\b\known_good_loader.bin
#>
param(
    [Parameter(Mandatory = $true)][string]$PackDir,
    [Parameter(Mandatory = $true)][string]$Loader,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [Parameter(Mandatory = $false)][string]$ToolBin = (Join-Path $PSScriptRoot '..\tools\RKDevTool_v3.37\bin'),
    [string]$ReferenceLoader,
    [string]$OsType = 'ANDROIDOS',
    [switch]$KeepRkaf
)

$ErrorActionPreference = 'Stop'

$afp = Join-Path $ToolBin 'AFPTool.exe'
$mkr = Join-Path $ToolBin 'RKImageMaker.exe'
foreach ($p in @($afp, $mkr)) { if (-not (Test-Path $p)) { throw "missing tool: $p" } }
if (-not (Test-Path (Join-Path $PackDir 'package-file'))) { throw "missing package-file in $PackDir" }
if (-not (Test-Path (Join-Path $PackDir 'parameter.txt'))) { throw "missing parameter.txt in $PackDir" }

$rkaf = [IO.Path]::ChangeExtension($OutFile, '.rkaf')

"==== pack (AFPTool) ===="
(& $afp -pack $PackDir $rkaf 2>&1) | Select-String -Pattern 'OK|Error|fail' | Select-Object -Last 3 | ForEach-Object { "   $($_.Line.Trim())" }
if (-not (Test-Path $rkaf)) { throw "AFPTool produced no rkaf" }
"   rkaf = $((Get-Item $rkaf).Length) bytes"

"==== wrap (RKImageMaker) ===="
(& $mkr -RK33 $Loader $rkaf $OutFile "-os_type:$OsType" 2>&1) |
    Select-String -Pattern 'Error|success|fail' | ForEach-Object { "   $($_.Line.Trim())" }
if (-not (Test-Path $OutFile)) { throw "RKImageMaker produced no image" }

"==== verify RKFW header ===="
$fs = [IO.File]::OpenRead($OutFile)
$h = New-Object byte[] 40
[void]$fs.Read($h, 0, 40)
$fs.Close()
$hdrLen = [BitConverter]::ToUInt16($h, 4)
$ldrSz = [BitConverter]::ToUInt32($h, 29)
$imgOff = [BitConverter]::ToUInt32($h, 33)
$ldrLen = (Get-Item $Loader).Length
"   total size   : $((Get-Item $OutFile).Length)"
"   hdr[4..5]    : $hdrLen        (expect 102)"
"   loader_size  : $ldrSz         (expect $ldrLen)"
"   image_offset : $imgOff        (expect $(102 + $ldrLen))"
$ok = ($hdrLen -eq 102) -and ($ldrSz -eq $ldrLen) -and ($imgOff -eq (102 + $ldrLen))
"   header check : " + $(if ($ok) { 'OK' } else { '** FAILED **' })

"==== compare loader region with the known-good loader ===="
if ($ReferenceLoader -and (Test-Path $ReferenceLoader)) {
    function Get-RegionHash([string]$path, [long]$offset, [long]$length) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $f = [IO.File]::OpenRead($path)
        try {
            [void]$f.Seek($offset, 'Begin')
            $buf = New-Object byte[] 4194304
            $remain = $length
            while ($remain -gt 0) {
                $n = $f.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $remain))
                if ($n -le 0) { break }
                [void]$sha.TransformBlock($buf, 0, $n, $buf, 0)
                $remain -= $n
            }
            [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
        }
        finally { $f.Close() }
    }
    $a = Get-RegionHash $OutFile 102 $ldrLen
    $b = (Get-FileHash $ReferenceLoader -Algorithm SHA256).Hash
    "   in-package   : $a"
    "   reference    : $b"
    "   loader match : " + $(if ($a -eq $b) { 'IDENTICAL' } else { '** DIFFERENT **' })
}

if (-not $KeepRkaf -and (Test-Path $rkaf)) { Remove-Item $rkaf -Force }

"`n==== done ===="
"   $OutFile"
"   import it in the tool's Firmware / upgrade page. Import needs no device."
