# Error catalogue and scripting traps

## 0. Mandatory first step - back up the partition table AND the mini loader

This is the non-negotiable Step 0 of `SKILL.md`, repeated here because it is the
most common way boxes get permanently bricked. **Before any backup, modification,
or firmware build**, first secure:

- **partition table** - `parameter.txt` (legacy `PARM` / `mtdparts`) or the GPT
  (`EFI PART` at LBA 1). On RK boxes the partition table lives in the **loader
  area (sectors 0..0x2000)**, so `rk_tool.ps1 export 0 8192 preloader_region.img`
  captures it together with the loader.
- **mini loader** - the combined `BOOT`/`LDR` container, carved out of the same
  region as `MiniLoaderAll.bin`. It is what revives a dead box and what every
  firmware package imports.
- **tool partition config** - the flashing tool's importable `.cfg` (INI-style,
  one `[<part>]` section per partition with `Name`/`Path`/`Type`/`Base`/`Length`/
  `Index`/`Mask`). Export it from the tool's 下载镜像 / 设备分区表 panel the
  instant the table is read. The tool flashes from this file, never from
  `parameter.txt` - without it you cannot write the partitions back even if you
  have every image.

The instant all three are on disk, **save the partition table and its tool config
in four copies** so a single lost/overwritten file cannot sink a restore. The
`.cfg` files are the flashing tool's native, importable partition layout - they are
what you load into RKDevTool / AndroidTool to actually flash, NOT the text
`parameter.txt`:

1. `parameter.txt` (or `gpt_parts.txt`) - the human-readable parsed table
2. `preloader_region.img` / the raw GPT block (sector 0 LBA 0..63) - the original bytes
3. `config_restore_stock.cfg` - the tool's importable config pointing at the
   **stock** backups (generated from the 下载镜像 / 设备分区表 panel the moment
   the table is read)
4. `config_flash_<modified>.cfg` - the tool's importable config pointing at the
   **modified** set

Rule 0 of `SKILL.md`'s hard-won rules is this, made operational. Never skip it to
"save time".

## 1. Firmware / packaging errors

| message | real cause | action |
|---|---|---|
| 固件中Loader摘要检查失败，请检查loader<br>`Error:Loading loader failed,err=-9` | the loader argument was a single rkbin component, or a wrong container format | pass a combined `BOOT`/`LDR ` container; see `firmware-package-format.md` |
| 载入固件失败<br>`Error:Loading firmware failed,err=-2009` | same family as above, from the v2.84-generation loader | same fix |
| 设备类型不匹配,停止执行! (during 下载Boot) | the loader's declared chip/DDR does not match the device | use the loader extracted from the device's own flash, or one tagged for the exact chip |
| 固件中Loader标识错误，请检查Loader<br>`Error:LoadFwProc-->create image object failed,ret=-5!` (also `-9`) | **the RKFW header's loader-identity field does not match the loader's own tag.** Header bytes `0x15..0x18` hold `8633` (what `RKImageMaker -RK3368` derives from the chip flag) while the loader's own bytes carry `41 30 33 33` = `A033`. The loader can be byte-identical to a package that imports fine and still be rejected - check the tag, not the loader | patch the header: byte `0x08` -> `00`, bytes `0x14..0x17` -> the loader's own 4-byte tag (`41 30 33 33` for the 219,470-byte RK3368 loader; read it from the loader at offset 20). Keep the size fields `RKImageMaker` wrote. Verified 2026-10-14: the patched package imports (固件版本 5.00 / Loader版本 2.48 / 芯片信息) and flashes |
| `Error:IsDharaImage-->file size is shorter than 0x7800` | a file-type probe line, **not** the real failure | ignore; look at the next error |
| `Error:ExportImageProc-->device did not support to read` | `ReadLBA: Disable` capability of the running loader | see backup-and-restore.md section 2 |
| `err=995` / `err=31` / `err=-8` on write/read | USB link instability | short cable, rear USB2 port, no hub, external power, close other flashing/phone tools, restart the tool |
| the same errors **and** no `VID_2207` device in `Get-PnpDevice` at all (not even an unknown/bang device) | the box is not on the host USB at all - wrong port, a charge-only cable, or it never reaches MASKROM | move it to a **rear USB 2.0** port and off every hub. On the 2026-10-15 machine two Genesys hubs were in the chain - `USB\VID_05E3&PID_0610` (USB 2.0) and `USB\VID_05E3&PID_0626` (USB 3.0) - and they produced a whole evening of `err=995/121` and `DownloadBoot Sended(0)`. Check with: `Get-PnpDevice -PresentOnly -Class USB`; an unknown device would instead indicate a missing driver |
| `Boot_VendorRequest-->DeviceIoControl failed,Total(N),Sended(0),...,err(31)` then `DownloadBoot-->Boot_VendorRequest471 failed,index(0)` | the RAM-loader download never started: **not a loader problem, a dead link** | see the note below; fix the physical path, re-enter MASKROM |
| **every export beyond LBA 0x10000 (32 MiB) reads back as one repeated byte (0xCC), with NO error in the log** | the device's LOADER-mode loader only serves the first 32 MiB and silently answers with filler beyond it. Different from the row above: here nothing fails, the data is just not real | see "silent 32 MiB read window" below - do not trust any image past that LBA |
| in **MASKROM** mode: `RKU_Write err=995`, `RKU_ResetPipe err=31`, `ExportImageProc-->RKU_ReadLBA failed,err=-3` | the ROM cannot read flash at all; a loader must be downloaded into RAM first, and none was configured | set a loader on the 升级固件 page (Loader field) or use a firmware package; "restart device" is greyed out until then. Not a link fault |

## 2. False signals - things that look like evidence and are not

**`RKImageMaker -unpack` is not a validator.** In every version tested it failed
on packages it had produced itself, including ones that later imported fine.
Using it as an oracle produced a wrong "the loader is fine" conclusion that cost
a full round of investigation. If you need an oracle, use the RKFW header fields
and the loader region hash.

**A plausible file size proves nothing.** An interrupted export leaves a file of
exactly the requested length whose tail was never written. Cross-check content
against a second independent capture.

**One failed command does not prove the data is broken.** In one instance a
one-line PowerShell check reported a 1.6 GB partition image as "1 byte". The file
was intact; the expression had collapsed an array to a string and indexed a
character. Before raising an alarm, re-derive the result a different way - and if
you already raised it, retract it explicitly.

**Version-dependent header fields: only two of them are checked.** `RKImageMaker`
ver 1.67 and ver 2.23 write different values into fields `[8..15]` of the RKFW
header, and neither matches a 2017 factory package exactly; most of that is noise.
Two fields are not: byte `0x08` and bytes `0x14..0x17` (the loader tag). When they
disagree with the loader's own tag the tool reports 固件标识错误 / loader 有问题 even
though the loader bytes are identical to a known-good package. Patching exactly
those two by hand is safe and worked (2026-10-14). Do **not** touch the size fields
`0x1C`/`0x20`/`0x24`, and do **not** splice another package's whole header onto your
payload: the tool then crashes (`tool_error.dmp`), which is worse than a clean
rejection.

**The silent 32 MiB read window (cost a whole fake "blank device" diagnosis).**
On one RK3318/RK3328 box (an RK device, Android 11) every export returned real data
up to LBA `0x0000FFFF` and then a single repeated byte `0xCC` - for every range,
at every starting LBA, with **nothing in the tool's log**. The result: `super`,
`userdata`, `recovery`, `logo` and two thirds of `boot` all looked "wiped", a
plausible "factory-half-flashed" story was built on it, and 28 GB of filler was
dumped. The device in fact booted and ran a full Android from `super`.

**Mechanism - it is the device's U-Boot, on purpose.** Rockchip's stock
`u-boot/cmd/rockusb.c` guards the USB dump path:

```c
static int rkusb_read_sector(struct ums *ums_dev, ...)
{
        lbaint_t blkstart = start + ums_dev->start_sector;
        if ((blkstart + blkcnt) > RKUSB_READ_LIMIT_ADDR) {
                memset(buf, 0xcc, blkcnt * SECTOR_SIZE);   /* <- the 0xCC */
                return blkcnt;                             /* success, no error */
        } else {
                return blk_dread(...);
        }
}
```

`RKUSB_READ_LIMIT_ADDR` is 32 MB. So the boundary (`0x10000` sectors = 32 MiB)
and the filler byte (`0xCC`) are both explained exactly, and *any* host tool
talking to this loader - RKDevTool, AndroidTool, rkdeveloptool - gets the same
filler. Source: the `xrock` project README documents the guard and the
`&& 0` patch for `RKUSB_READ_LIMIT_ADDR` (gitee.com/xboot/xrock).

How to catch it before believing anything:

* the boundary was exactly `LBA 0x10000` = 32 MiB, an integer - a real
  interrupted flash does not stop on that boundary. Suspect a limit, not content;
* compare the *declared* payload size with where the data actually ends: a
  `boot.img` header said kernel = 31,238,160 B at 25 MiB, i.e. content to
  54.8 MiB, but the data stopped at 32 MiB - a truncated kernel could not boot,
  yet the box did;
* two independent exports agreeing proves only that the reader is *deterministic*,
  not that it is *right*. My 18/18 cross-check passed on the filler as well;
* the cheapest oracle is the running system: `adb shell cat /proc/partitions` and
  `mount` (here: five `dm-N` devices mapped out of `super`, `/vendor`, `/product`,
  `/odm`, `/system_ext` all mounted). If the box boots, `super` has content -
  full stop.

Read paths that bypass it, because U-Boot is not the thing serving the reads:

* **MASKROM mode** - the ROM plus the host-downloaded loader (rkbin usbplug) do
  the reads, and that code has no such guard. Requires a loader file for the
  exact chip in the tool's Boot/Loader field; without one every operation fails
  with the MASKROM error row above.
* **root inside the running Android** - `dd` on `/dev/block/mmcblk*` is a kernel
  read. `su` is useless from `adb shell` (it runs with `no_new_privs`, so a
  SUID-root `su` cannot raise privileges and says `setgid failed`), and
  `adb root` is refused on `user` builds; recovery's adbd does run as root.
* patching `RKUSB_READ_LIMIT_ADDR` in U-Boot and flashing it - documented, but
  invasive; do not reach for it first.

**The guard lives in usbplug too, and it leaves a parity artifact.** The same
32 MB check is in the MASKROM loader (`_usbplug_*.bin`), located by disassembly:

```
00A0B0  ldr  w8, [x10]          ; request end
00A0B4  ldr  w9, [x9, #0x9c4]   ; limit (32 MB)
00A0B8  cmp  w8, w9
00A0BC  b.hs #0xa104            ; -> 0xA104: movz w1,#0xCC ; bl memset
00A0C0  ...real read...  bl #0x9650
```

NOPing `00A0BC` (`42 02 00 54` -> `1F 20 03 D5`) and rebuilding the loader with
`boot_merger` removes the wall - the loader only ever runs from DDR, so nothing is
written to flash and a bad patch costs one power-cycle. Reads past 32 MiB then come
back **correctly aligned but with every even-numbered 64 KiB block replaced by
0xCC** (a 1 MiB probe showed exactly 8 filler + 8 real 64 KiB blocks, alternating).
Read the region **twice, 64 KiB apart**, and merge per block: take A's block unless
it is pure 0xCC, then take B's at +65536. For a 3 GB `super` that gave 24,896
blocks from each pass and **0 blocks filler in both**.

Verifying that merge needs no reference image, because liblp signs itself: the
geometry, the metadata header and the tables each carry a **SHA256** - verify all
three (`lpverify.py`), then cross-check the extents against the live `dm-*` sizes
(`system 1133.6MB`, `system_ext 42.6MB`, `vendor 146.9MB`, `product 140.5MB`,
`odm 0.5MB` all matched to the megabyte). Two independent proofs beat any vibe.

**RECURRENCE 2026-10-15 (an RK device / RK3566): read this section BEFORE touching a box.**
The same 32 MiB wall bit again, in a new disguise, and cost another fake
"device is blank" diagnosis - even though everything needed to avoid it was
already written above. Two process rules, both learned the hard way:

* **Open this file first.** The failure mode was not ignorance of the guard, it
  was starting to diagnose before re-reading the catalogue.
* **Never judge a read by the first bytes of the destination.** `super` on a
  dynamic-partition device legitimately has large empty stretches (in the an RK device
  Pro image the real `system` sits in the *middle* of `super`), so "offset 0 is
  filler" proves nothing either way. The cheap, decisive test is a **boundary
  sweep**: read 4 KiB at increasing LBAs from 0 to 64 MiB and print the number
  of distinct bytes per sample. Signature of the guard:
  `gap = 0x00 filler` / `real = many distinct bytes` / **`0xCC from LBA 0x10000
  (32 MiB) upward`**, and reads at >= 40 MiB fail outright. An unformatted or
  interrupted flash does not stop on an integer 32 MiB boundary.

**The guard's exact address in the RK3566 usbplug, so the patch needs no guessing.**
`rkbin/bin/rk35/rk356x_usbplug_v1.17.bin` (98,708 B):

```
0x0A0A0  cmp  w8, w9              (6B09011F)   ; request end vs limit
0x0A0A4  b.hs -> 0x0A0EC          (42020054)   ; <-- NOP this (cond=2 = HS)
0x0A0BC  bl   0x9888                            ; real read
0x0A0F4  movz w1, #0xCC           (81198052)   ; filler
0x0A0FC  bl   0xDD78                            ; memset
```
(There is a second, unrelated `movz w1,#0xCC` at `0x0A320` next to
`movz w27,#0x55AA` logic and with **no** preceding `b.hs` - do not patch it.)
Patch byte pattern `42 02 00 54` -> `1f 20 03 d5`, confirm with `boot_merger`
(`Pack loader ok`, output still starts with `LDR `), and keep the unpatched file
for comparison. Verified 2026-10-15.

**LOADER mode reads are served by the DEVICE's own loader - you cannot swap it
in.** Documented empirically: the tool's log shows `测试设备开始` -> `测试设备成功`
in **2 ms** with no `DownloadBoot` line, and `config.ini` has no Loader entry, so
a loader set on the 升级固件 page is *not* used by export/read. Consequence: with
the box in LOADER mode the 32 MiB wall cannot be lifted from the host, no matter
which loader you supply (the device's flashed loader answers the reads).
Options, in order of preference:

1. **MASKROM mode** - the ROM plus the host-downloaded loader do the reads
   (a loader for the exact chip must be set, see the MASKROM row in section 1);
   patch that loader first, then read. Nothing is written to flash.
2. **Root inside the running Android** - `dd` on `/dev/block/by-name/super` is a
   kernel read with no guard.
3. Flashing a patched bootloader - invasive, last resort.

Reading `super` after the patch still shows the 64 KiB parity artifact, so use
the two-pass `merge_super.py` + `lpverify.py` pair described above.

**"The other partitions read fine, so this one must too" - a false inference.**
2026-10-15 an RK device audit of every exported image, measuring the **absolute end of
real data** per partition: security 5 MB, uboot 12 MB, misc 16 MB, dtbo 21 MB,
vbmeta 25 MB - all fine **because they sit below 32 MiB**. The only partition
that straddles the wall, `boot` (declared 40 MiB), had real data ending at
exactly **0.0312 GiB = 32 MiB**; every partition fully above it (recovery, backup,
cache, metadata, logo, `super`) was 100% filler. A full scan of the 3.04 GiB
`super` image: `0xCC = 100.000%`, **0 of 778** 4 MiB blocks with data, and no
`gDla`/`0PLA`/ext4/erofs magic and no ASCII strings anywhere.
Flash silicon does not truncate content on an integer 32 MiB boundary. So: when
someone reasons "other partitions are fine, therefore this one is fine", compute
that absolute end offset for each partition and compare with 32 MiB - one number
settles it. Also note the corollary: *any* partition at or above 32 MiB is
unreadable in LOADER mode, so an export that "succeeded" for it proves nothing.

**MASKROM: use 「高级功能 → Boot → 下载」 (RAM only), NEVER 「升级固件 → 升级」 (writes IDB).**
2026-10-15 an RK device: a *patched* loader was deliberately flashed by pressing 升级 on the
升级固件 page. The log stopped at `INFO:DownloadIDBlock-->New IDB` - i.e. the tool
had begun rewriting the IDB/loader area (**LBA 0x40, below the first GPT
partition**) and died there. Result: the box no longer reaches LOADER mode at all.
Everything else survived, because the upgrade sequence writes the IDB first and
never got to the partitions - `uboot`, `boot`, `super` and all data were untouched.

Recovery path that works:
1. enter MASKROM (power off, hold the reset button, plug USB, hold ~4 s);
2. set the loader back to the **stock** container - e.g.
   `rkbin/rk356x_loader_v1.26.114.bin` (481,728 B, `LDR ` header);
3. let the tool rewrite the IDB on the 升级固件 page.

Two traps to remember:
* **The device's own `uboot` partition is NOT a loader container on this platform.**
  Its 4 MiB image starts with `d0 0d fe ed` (an FDT/DTB header) - it is u-boot
  proper, so it cannot be handed to the tool as a loader. On older SoCs
  (RK3368/an RK3368-class device) the same-named partition *was* the `LOADER` container; do not
  generalise from that case.
* **RAM vs flash.** `Boot` field + 下载 = loader runs from DDR, nothing is written,
  a bad patch costs one power cycle. `升级` = writes the IDB/loader area to flash
  and a bad patch means MASKROM recovery. Always start with the RAM path; only
  flash a loader when you are certain of the file.

**An `-os_type` sweep proves nothing on v3.37.** Its `RKImageMaker` ignores the
flag entirely - five different values produced byte-identical headers.

## 3. Scripting traps (all hit during this project)

1. **PowerShell aliases shadow your functions.** `function Cat { ... }` silently
   resolves to `Get-Content`; the "concatenated" file is never created and every
   downstream error becomes a phantom. Use distinctive names
   (`Join-BinaryParts`) - and never define `cat`, `sort`, `where`, `select`.
2. **`[Text.Encoding]::Latin1` does not exist on PowerShell 5.1.** Use
   `[Text.Encoding]::GetEncoding(28591)`. A null encoding silently swallows every
   subsequent `-match`, producing an empty "no matches" report that looks like a
   clean result.
3. **Two-hex-field file names invite off-by-one parsing.** `name_START-COUNT.img`:
   take the FIRST field as the start. Using the last one makes exactly the
   partitions where start == count pass, which is a recognisable signature of the
   bug rather than of bad data.
4. **Array element extraction**: `$arr[1]` is a character if `$arr` turned out to
   be a string. Cast to `[string]` or index a strongly-typed `[pscustomobject]`.
5. **Chinese in script comments**: a file written as UTF-8 without BOM and read by
   a GBK code page turns into mojibake that can break parsing. Keep `.ps1`
   comments ASCII; write Chinese only into docs, and write those with a UTF-8 BOM
   (`New-Object Text.UTF8Encoding($true)`).
6. **`Get-PnpDevice` can miss an attached Rockchip device.** Do not conclude "no
   device" - cross-check the tool's status bar before reporting that a step was
   skipped for that reason.
7. **GUI automation by coordinates is dangerous.** Address controls by their
   control id (`GetDlgCtrlID`), never by screen position, so erase buttons cannot
   be hit by accident. `rk_tool.ps1` is built this way.
8. **The tool's log is not a success signal.** In the versions tested it records
   ERROR lines only - a successful test/read/export writes nothing. Detect
   completion by the button's enabled/disabled transition instead.
9. **Python helper scripts need UTF-8 mode on a Chinese Windows console.** The
   locale encoding there is GBK, so `Path.read_text()` on a UTF-8 file raises
   `UnicodeDecodeError`, and printing any non-ASCII raises `UnicodeEncodeError`.
   Run `python -X utf8 script.py`, or set `PYTHONUTF8=1` and
   `PYTHONIOENCODING=utf-8`. This first bit the skill's own packaging step: the
   official validator and packager both died on it before the mode was set.

## 4. Process lessons

- **Small artifact first.** The firmware import check fires before any content is
  read, so a package without `system` validates the loader in seconds instead of
  minutes. This project wasted several long build-flash cycles before adopting it.
- **Change one variable per attempt.** When a whole axis is swept at once, a
  success cannot be attributed and a failure cannot be localised.
- **Prefer the same model as reference.** The decisive break came from extracting
  a loader out of a factory package for the *same model and chip family*, not from
  any parameter sweep.
- **Derive constraints from the device, never from a sibling device.** Capacity,
  parameter format and loader all differ within one product family.
- **Know when to stop.** Firmware packaging was never a prerequisite for the
  actual goal (a restorable backup). State that plainly when it applies, and keep
  the non-destructive path working while the fancy one is being chased.

## 5. 2026-10-14 - an RK3368 device complete package: what actually solved it

**A. The loader was never the problem; the header tag was.**
The winning comparison was against the 2017 reference package for the *same chip*
(`D:\a downloaded archiveDownload\RK3368-安卓5.1-a factory firmware image-20170503版`, imports fine).
Its loader is byte-identical (sha256 `9987d7a2…`, 219,470 bytes) to the one we had
already used, so the loader was ruled out; the difference was in the RKFW header.
Fix: patch bytes `0x08` -> `00` and `0x14..0x17` -> the loader's own tag `41 30 33 33`
(`A033`). Result: import OK (固件版本 5.00 / Loader版本 2.48 / 芯片信息 RK330A).
**Do not** wrap our payload in the reference package's whole header: mismatched size
fields made the tool crash (`tool_error.dmp`) instead of rejecting cleanly.

**B. Do not strip the stock launcher beyond the UX layer.**
Removing 13 `/app` components broke three unrelated things at once on the real box:
the input method could not be used, WiFi **crashed the moment connect was pressed**,
and USB devices were not recognised at all. Only the UX-level components need to go:
the stock **launcher** (replaced by an alternate launcher such as Emotn), the stock
**app store**, and the **OTA updater** (it would undo the change). Keep **everything** else:
`SettingService`, `Settings2`, `MiddleLayer`, `BackgroundService.apk`,
`UsbFactory.apk`, `UsbService.apk`, `HomeKey`, `MediaPlayer`, `FileBrowser`,
`SambaService`, `ScreenSaver-release.apk`, `FactoryTest.apk`, `LatinIME`, `OpenWnn`.
System services and USB/input/storage components are not bloat: on a TV
box they own settings, connectivity, storage mounting and key handling.
Verify after editing: `e2fsck -fn` reports `Filesystem state: clean`, and the `/app`
listing still contains every component of the keep list (a missing one is the bug).

**C. A box that boots straight into LOADER is not fixed by system alone.**
It was flashed system-only twice (`RunProc … ret=1` both times) and still came up in
LOADER. Restore the boot chain first (uboot, trust, misc, resource, kernel, boot,
recovery, then system). A whole-package upgrade does exactly that; the `loader` row
can stay unticked because a box that reaches LOADER already has a working loader.

**D. `AFPTool -unpack` / `RKImageMaker -unpack` traps.**
* The **output directory must exist first**, else `Error:out is not exist!` - this
  one line cost several rounds today.
* Both tools are unreliable with non-ASCII paths (`Error:Check <mojibake>`); pack and
  unpack inside an ASCII directory and copy the result back.
* Their success is not a validation - compare member hashes against `Image\`.

**E. Housekeeping that silently breaks the next step.**
* On D: deletes go to the **Recycle Bin**: space only returns after
  `Clear-RecycleBin -DriveLetter D -Force`. A 4.66 GB unpack leftover plus the bin
  took the disk to 0 bytes free, and every subsequent script write produced a
  **0-byte file** - which looks like an editor/encoding failure but is ENOSPC. Check
  `Get-PSDrive` before building, and clean up unpack directories.
* Long builds create hard-link farms: verify with `os.path.getsize`, not by trusting
  that a directory "has" the data.

**F. Driving the tool (v3.37) from scripts.**
* `(Get-Process RKDevTool | Select -First 1).MainWindowHandle` can resolve to a
  `ZTitleTip` popup with no controls; find the `#32770` frame whose title matches
  `v3.|v2.` instead.
* `PostMessage(BM_CLICK)` does not reliably reach owner-drawn buttons (执行 / 固件 /
  升级) - use a real mouse click at the control rect.
* 加载分区表 could never be made to work; the verified route is the **config.cfg**
  route from `rk_config.py make` (rows with an image are ticked, rows without are
  skipped), so "flash only X" is simply a config that carries one image.
* **The skill's own `.ps1` scripts must stay pure ASCII** - PowerShell 5.1 decodes
  them as ANSI and non-ASCII characters corrupt the whole file.

**G. Flash reliability and honest documentation.**
* `err=31` + `RKU_ResetPipe --> CreateFile … failed,err=2` in the middle of a 1.6 GB
  write means the box fell off the USB bus, not a package defect (the ten smaller
  partitions of the same package wrote fine in that same run). Rear USB 2.0 port,
  short cable, no hub, box on its own power supply, retry.
* The delivered an RK device 完整包 was documented as "备用/未实机验证" - and in fact never
  imported at all until today. Mark unverified paths as unverified instead of
  presenting them as a working alternative.

**H. Material must match the model, and the `loader` row holds the partition table.**
* `the device` and `another variant` are different firmware families: `ro.product.model` in
  `build.prop`, the DTB inside `resource`, `baseparamer` and the system tree are all
  model-specific. Installing the device material on a another variant box shows up as *WiFi crashing
  the moment connect is pressed, USB devices not recognised, and a box that falls
  back into LOADER on every power-up*. Check `ro.product.model` in both the package
  and the device before flashing - and say plainly that the model is unverified
  rather than assuming it.
* **"Always boots into LOADER" is usually U-Boot failing and falling back to
  rockusb**, not a dead box. Two causes seen: a wrong device tree, and a wrong
  partition table.
* The partition table lives in the **`loader` area (sectors 0..0x2000)**, in the
  `PARM` block at sector 0, i.e. inside the same image the tool's `loader` row
  writes. A box that has been flashed with someone else's package usually carries
  *that* package's parameter there, so U-Boot looks for boot/system at the wrong
  offsets and gives up into rockusb - while every partition we write by address
  (via `config.cfg`) lands correctly and the log still reads `ret=1`. Writing our
  own 4 MiB loader-area image (which starts with `PARM` + the parameter text) fixes
  the table and the bootloader together.
* Order that made sense on this box: 1) match the model, 2) write the boot chain
  (uboot/trust/boot, plus `resource`/`kernel` if the DTB is wrong), 3) rewrite the
  `loader` area so the parameter matches, 4) clear `misc` and the start of
  `userdata` so the BCB and the stale `/data` cannot interfere, 5) power-cycle by
  unplugging instead of letting the tool reset.
* Writing the `loader` area rewrites the IDBlock/DDR init too. On the same SoC this
  is normally fine, but if the box then stops answering in LOADER it is still
  reachable in **MASKROM** (hold the reset key while plugging in) and can be flashed
  from there - say this out loud before doing it.
