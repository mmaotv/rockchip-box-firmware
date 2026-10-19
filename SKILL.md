---
name: rockchip-box-firmware
description: End-to-end workflow for Rockchip (瑞芯微) TV boxes and dev boards - identify the device, back it up completely, modify the Android system (launcher / pre-installed apps), rebuild a flashable update.img, verify every step, and archive it so a bricked box can be recovered. Covers RK3368/RK330A legacy boxes (rk29xxnand parameters) and RK3566/RK3568 boxes (Android dynamic partitions super/dtbo/vbmeta), RKDevTool/AndroidTool UI automation, RKFW/RKAF package internals, and the loader-container requirement that decides whether a firmware package imports at all. This skill should be used when the user wants to back up, restore, modify the system of, or re-package firmware for a Rockchip TV box or development board (RK-based set-top boxes and development boards), when they mention RKDevTool, AndroidTool, 瑞芯微, loader, update.img, 升级固件, 下载镜像, 分区备份, 改 system, or 做固件包, or when they hit errors such as 固件中Loader摘要检查失败, Loading loader failed err=-9, 载入固件失败 err=-2009, or 设备类型不匹配.
---

# Rockchip Box Firmware

## Overview

A repeatable pipeline for Rockchip (瑞芯微) set-top boxes and boards:

**识别设备 → （Step 0: 先备份分区表 + mini loader） → 完整备份 → 校验 → 改 system → 打包固件包 → 验收 → 归档**

The pipeline is identical across Rockchip SoCs. Only three things change between
devices: the **partition table format** (legacy parameters vs GPT), the **loader
container**, and the **tool version pair**. Everything else carries over.

## Core principle: every step must be checkable without the device

Almost every failure in this domain comes from validating with the wrong oracle.
In one recorded session, ten consecutive firmware packages failed because the
only "acceptance test" was `RKImageMaker -unpack`, which is **unreliable in every
version tested - it cannot even unpack the packages it produced itself**. Real
progress only started when each step got an independent, byte-level criterion:

- backup: file size == sector count x 512, **and** cross-check against a second
  independent dump
- firmware package: RKFW header fields, and the loader region's SHA256
- system content: byte-scan for launcher/app markers

**Never** conclude "it is correct" from a single tool's own verdict, and never
conclude "it is broken" from a single failed command - re-derive the check from
the bytes first.

## Workflow

> **Step -1, non-negotiable: read `references/pitfalls.md` end to end before
> diagnosing a device.** On 2026-10-15 this was skipped and a trap that section 2
> already documents (the silent 32 MiB read wall) was re-diagnosed from scratch,
> producing a second fake "the device is blank / half-flashed" story - after the
> identical mistake on an RK device. Believing a read artifact costs a day; the
> boundary sweep in `pitfalls.md` (4 KiB samples from LBA 0 to 64 MiB) costs 30
> seconds and identifies it immediately.

> **Step 0, non-negotiable - back up the partition table AND the mini loader
> FIRST.** The instant a task touches a device to *back up partitions/firmware*
> or to *modify* anything, the very first action is **not** to read a partition,
> write a file, or change a setting. It is to secure the two artifacts that, once
> lost, make the box permanently unrecoverable:
> - **partition table** - legacy (RK3368/RK330A): export sector 0 and pull
>   `parameter.txt` / `mtdparts` out of the `PARM` block
>   (`rk_tool.ps1 export 0 8192 sector0.img`). GPT (RK3566/68): also press
>   **设备分区表** on the 下载镜像 page (`rk_tool.ps1 click 1052` then
>   `rk_tool.ps1 listbox 1003`) and save the tool's own `NO / LBA / Size / Name`
>   panel as `parameter.txt` / `gpt_parts.txt`. In all cases the first 0x2000
>   sectors (`rk_tool.ps1 export 0 8192 preloader_region.img`) also carry the GPT
>   and the loader area.
> - **mini loader** - export the loader region (the first 0x2000 sectors already
>   captured above) and carve out `MiniLoaderAll.bin` from the loader offset
>   (e.g. LBA 0x40 for RK3328). This combined BOOT container is what you must
>   re-flash to revive a dead box and what every firmware package imports.
> - **tool partition config (the importable `.cfg`)** - the `parameter.txt` above
>   is only half the job. The flashing tool (RKDevTool / AndroidTool) does **not**
>   flash from a text file; it flashes from its own **importable partition config**
>   - the `.cfg` (INI-style, one `[<part>]` section per partition carrying
>   `Name` / `Path` / `Type` / `Base` / `Length` / `Index` / `Mask`). The instant
>   the table is read, export this config from the tool's 下载镜像 / 设备分区表
>   panel and save it beside `parameter.txt`. This `.cfg` is the *only* artifact
>   the tool can re-import to flash partitions - you can dump every byte and still
>   be unable to write it back without it. It is a first-class backup, equal to the
>   loader and the table.
>
> Do **not** proceed to any other backup or modification until the table, the
> loader, AND the tool config are on disk, verified, and saved in four copies (see
> `pitfalls.md` 0.1). If they were already
> captured in a *previous, verified* session on the *same* device, you may skip -
> but say so explicitly and re-confirm their hashes against the live device first.

### Step 0 - Tooling

Put these in one archive folder before touching a device:

- `RKDevTool_v3.3x` (newer boxes) and `AndroidTool / RKDevTool v2.84` (legacy boxes)
- **`DriverAssitant_v5.x.zip` - the Rockusb driver.** Without it a bricked box
  cannot be recognised at all. This is the single most commonly forgotten item.
- A USB2 port, a short cable, no hub, external DC power to the box.

### Step 1 - Identify the device (read-only, never assume)

Do **not** trust the model number on the case, and do not reuse another device's
parameters. Read identity from the flash itself:

- USB id: `Get-PnpDevice | ? InstanceId -like '*VID_2207*'` (note `Get-PnpDevice`
  sometimes misses the device; also check the tool's status bar)
- **sector 0 of the device**: legacy boxes store a `PARM` block with
  `MACHINE_MODEL`, `MACHINE_ID` and `MACHINE: 3368` etc. Newer boxes hold a GPT
  (`EFI PART` at LBA 1) - parse it for the real partition list and capacity.
- The tool's status bar text (`发现一个LOADER设备` / `Found One LOADER Device`)
  and, for the chip, the tool's `芯片信息`.

Export sector 0 first with `rk_tool.ps1 export 0 8192 sector0.img` and read it.

### Step 2 - Back up everything, then verify

Export per partition (or by address range for a full disk), always **including
sector 0** - it holds the parameter block / IDBlock, and a restore that starts at
sector 0x2000 cannot revive a dead box. Large regions are exported in ~2 GiB
chunks and concatenated.

Then verify with `scripts/verify_backup.ps1`:

```
.\verify_backup.ps1 -PartitionDir <dir> -FullDisk <full.img> -WriteHashList <dir>\sha256.txt
```

It checks sizes and cross-checks every partition image against the full-disk
image byte for byte. Read its header comment before changing the parser - the
**start sector is the FIRST hex field** in `name_START-COUNT.img`.

A partition that is legitimately all zeros (`misc`, `kpanic`) is normal, and an
all-zero run inside `system` is just unused ext4 space - cross-checking proves
whether zeros are "内容本来如此" or a failed read.

### Step 2b - Write the tool's partition-table config (do not forget this)

A backup of partition images is only half a restore kit: the "下载镜像" page needs
one row per partition, and typing 15 addresses by hand is where restores break.
Generate the config the tool loads:

```
python -X utf8 scripts\rk_config.py make <spec.csv> <out.cfg>    # storage: 1=EMMC
python -X utf8 scripts\rk_config.py selftest <tool_written.cfg>  # proves the writer
```

**Include every partition of the device's table, including the ones with no
image** (write them as rows without an `image_path` - they are stored unticked so
the tool will not try to write them). Leaving `super`/`userdata` out of the list
because "they looked empty" makes the row list disagree with the device and is
read as an incomplete backup. Full details, the byte layout and the two GUI traps:
`references/tool-config-format.md`.

Then check the row list against the device itself: press **设备分区表** on the
下载镜像 page - the tool prints its own `NO / LBA / Size / Name` panel, which is the
cheapest independent oracle for start sectors and sizes.

For a region too large to hold twice (a 27 GB `userdata`), dump it with
`scripts/append_export.ps1`: export one chunk, append it to the target, delete the
chunk, resume from `<target>.progress`.

### Step 3 - Modify the system

Windows cannot mount ext4. Use WSL (Ubuntu) with `e2fsprogs`/`debugfs`, or
`e2fsprogs` + `simg2img` for sparse images.

**Check the partition layout first:**
- legacy box: a standalone `system` partition - edit it directly
- Android 10+ box: `system/vendor/product/...` live inside a single `super`
  partition (dynamic partitions), but each logical partition is just a **linear
  extent** inside `super`, so it can be edited **in place** - no
  `lpunpack`/`lpmake` needed:
  1. parse the LP metadata and read the extent map (`scripts/lpverify.py`)
  2. carve the logical partition's byte range out of `super`
  3. edit that ext4 with `debugfs` (or a loop mount) **without changing its size**
  4. write the range back to the same offset inside `super`
  The LP metadata stays untouched, which is exactly why this is safer than a
  rebuild. Reach for `lpunpack`/`lpmake` only when the *layout* must change (grow
  a partition, add one). `debugfs` edits ext4 images a kernel refuses to mount
  read-write (`shared_blocks`).

**The LP magics are easy to get wrong.** `super`'s geometry sits at offset 4096
with magic **`0x616C4467`**; slots start at 12,288 and are spaced by
`metadata_max_size`, each beginning with an `LpMetadataHeader` of magic
**`0x414C5030`**. Descriptor offsets inside that header are relative to the *end*
of the header, not to the slot start. `0xD95EC667` is **not** a liblp magic -
searching for it finds nothing and proves nothing.

**`0xCC` is never content.** Rockchip's read path writes it when it cannot serve a
read (see `pitfalls.md`). A partition reading back as solid `0xCC` is not blank and
not "factory-half-flashed" - the *reader* refused. Prove the state with the
format's own checksum (GPT CRC32, liblp SHA256) before saying anything about the
device, and never report "the system is missing" on the strength of an export.

Then prove the change landed with `scripts/scan_markers.py`:

```
python scan_markers.py stock_system.img modified_system.img
```

Keep a stock image as the baseline; distinctive markers (`Emotn`, `dangbei`, app
names) show what actually got in. `Launcher` alone is meaningless - it matches
framework strings in every image.

### Step 4 - Build the firmware package (the loader is the hard part)

```
.\build_firmware.ps1 -PackDir <packdir> -Loader <loader.bin> -OutFile <update.img> `
                     -ToolBin '<...>\Rockchip-AndroidTool_Release_v2.84\bin' `
                     -ReferenceLoader <known_good_loader.bin>
```

The pack directory holds `package-file`, `parameter.txt` (take it from the
device's sector 0), the loader, and the partition images. Mirror the layout of a
factory package of the same model.

**The one rule that decides success:** the loader argument must be a **combined
container** embedding DDR init + FlashBoot/SPL + usbplug - not a single rkbin
component. Feeding a single component yields
`固件中Loader摘要检查失败` / `Loading loader failed,err=-9` (v3.x) or
`载入固件失败 err=-2009` (v2.84). The fastest reliable source of a correct loader
is **extracting it from a factory `update.img` of the same model**: it sits at
offset 102, with length = `u32 LE @ 29`. See
`references/firmware-package-format.md` for the byte layout and the acceptance
criteria. Both are summarised by a single number pair per device, e.g. RK3368:
`loader_size = 219470`, `image_off = 219572`.

Build a **small test package first** (omit `system`): the import check fires
before any content is read, so a lean package proves the loader in seconds. Only
then build the full one. Keep the result under ~2 GB - these tools are 32-bit.

### Step 5 - Verify, then archive

- import the package in the tool's 升级固件 page (needs no device)
- record the header fields and the loader SHA256 into the archive's doc
- archive must be **self-contained**: images + tools + driver + docs + one
  factory reference package + `sha256.txt`. Then copy it to another physical disk.
  A backup with only one copy is not a backup.

Restore paths, in order of preference: `下载镜像` (per partition, non-destructive)
→ firmware package (`升级固件`, rewrites the loader/IDB) → `强制按地址写` with the
full-disk image (last resort for a brick). Details in
`references/backup-and-restore.md`.

## Device family matrix

| | legacy (RK3368/RK330A, Android 5.x) | modern (RK3566/RK3568, Android 11+) |
|---|---|---|
| partition table | `PARM` block at sector 0, `mtdparts=rk29xxnand:...` | GPT, `EFI PART` at LBA 1 |
| full-disk read | per-partition export works | **silent 32 MiB wall**: past it every byte is `0xCC`, nothing in the log; patch the loader + merge two parity-shifted passes (`pitfalls.md`) |
| system | standalone partition | inside `super` (dynamic); edit the logical partition **in place** along its extents, lpunpack/lpmake only to resize |
| loader | `BOOT` container, e.g. 219,470 B | built by `boot_merger` from `RKBOOT/RK356xMINIALL.ini` |
| tool pair | AndroidTool v2.84 (AFPTool v1.65 + RKImageMaker ver 1.67) | RKDevTool v3.3x (AFPTool v2.28 + RKImageMaker ver 2.23) |
| typical params | `FIRMWARE_VER`, `MACHINE`, `CMDLINE ... mtdparts=` | `parameter.txt` + GPT backup |

## Hard-won rules (each cost hours)

> **Rule 0 - before any other rule: back up the partition table and the mini
> loader FIRST.** Whether the task is to back up partitions/firmware or to modify
> the system, the partition table and the loader are the first bytes to leave the
> device and the last you can ever get back. Do Step 0 before anything else. A box
> with a wiped partition table and no loader cannot be recovered even with the
> correct images.

1. **Never assume the device model.** Read sector 0. A box was silently a
   different chip/capacity than the one being worked from, and parameters from
   the wrong device would have bricked it.
2. **`RKImageMaker -unpack` is not a validator.** It fails on packages it built
   itself. Do not use it to accept or reject anything.
3. **The loader must be a combined container** (see Step 4). Single components
   never work, regardless of tool version, `-os_type`, size, or RKAF builder.
4. **Match the tool generation** end to end - do not pair a 2024 RKAF with a 2021
   wrapper.
5. **Small package first.** The import check precedes content reading.
6. **Verify content, not just size.** An interrupted export leaves a
   right-sized file full of junk. Cross-check against a second dump.
7. **Include sector 0** in any backup you might restore.
8. **Write scripts with ASCII comments and unique function names.** PowerShell
   resolves `Cat`, `Sort` etc. to its own aliases, which silently breaks
   file-concatenation helpers.
9. **No `[Text.Encoding]::Latin1` on PowerShell 5.1** - use
   `[Text.Encoding]::GetEncoding(28591)`.
10. **Chinese docs need a UTF-8 BOM**, or Notepad shows mojibake.
11. **Verify a device is really absent** (`Get-PnpDevice` can miss it) before
    claiming a step was skipped for that reason.
12. **A backup that silently drops two partitions is not a backup.** An empty
    looking `super`/`userdata` still gets a row in the tool config and, if a full
    dump is asked for, a dump - the owner decides, not the tool operator. Say
    "sampled 0xCC at N points" and let them choose.
13. **`config.cfg` is read relative to the working directory**, so a correct file
    placed next to the exe can be ignored. Start the tool with
    `-WorkingDirectory <dir>`, or load an absolute path via 加载分区表.
14. **Scripts that touch Chinese paths need the UTF-8 BOM.** PowerShell 5.1
    parses BOM-less `.ps1`/text as ANSI and mangles `01_备份镜像` into a path that
    does not exist.
15. **`0xCC` is filler, not content.** Solid `0xCC` means the reader refused, and
    it does so *silently*. Run a byte verdict (`scripts/checkread.py`) before
    believing a partition is empty, and prove correctness with the format's own
    checksums (GPT CRC32, liblp SHA256) rather than with a tool's exit status.
16. **"The device has no system" is usually a reader problem.** On RK boxes the
    Rockusb path refuses everything past 32 MiB - in U-Boot *and* in the MASKROM
    usbplug. Patch the loader (`scripts/patch_usbplug.py`) and merge two
    parity-shifted passes (`scripts/merge_two.py`) instead of concluding the flash
    is empty. The guard is a `memset(buf, 0xcc, ...)` that returns success.
17. **MASKROM only accepts a loader from the ROM.** If a loader already runs from
    DDR, `下载 Boot` silently does nothing: re-enter MASKROM first. The tell is the
    PnP instance id losing its serial number (`...\6&2EA33E13&0&2` instead of
    `...\the device serial`); after a good download the serial returns.
18. **Back up the partition table and mini loader before any other action.**
    This is Rule 0 made operational (see Step 0 for the exact commands). It
    applies to *both* backing up and modifying: do not read a partition, write a
    file, or change a setting until the partition table (`parameter.txt` / GPT)
    and the loader (`MiniLoaderAll.bin`) are on disk, verified, and saved in four
    copies. Skipping it to "save time" is how boxes become permanently bricked.

Full error catalogue: `references/pitfalls.md`.

## Resources

### scripts/
- `rk_tool.ps1` - drives the RKDevTool/AndroidTool GUI by **control id** (never
  screen coordinates, so destructive buttons cannot be hit by accident).
  Actions: `dump`, `text`, `click`, `settext`, `show`, `log`, `dialogs`, `ok`,
  `dlgset <id> <text>`, `listbox <id>`, `observe`,
  `export <startLba> <count> <dest>`, `plan <specFile>`.
  Its header documents the tool's quirks - read it first.
- `verify_backup.ps1` - size checks, cross-checks partitions/userdata against a
  full-disk image, emits `sha256.txt`.
- `rk_config.py` - read/write the tool's image-download config (`CFG\0`):
  `make <spec.csv> <out.cfg> [storage]`, `dump <file>`, `selftest <file>`.
  `selftest` rebuilds a file the tool wrote and diffs it, which is what proves
  the writer for every config generated afterwards.
- `append_export.ps1` - dump a region bigger than the free space: export a
  chunk, append it to the target, delete the chunk, resume from `.progress`.
- `build_firmware.ps1` - AFPTool + RKImageMaker, then verifies the RKFW header
  and compares the loader region against a known-good loader.
- `scan_markers.py` - byte-scans images for launcher/app markers, with a
  side-by-side summary for comparing stock vs modified.

### references/
- `firmware-package-format.md` - RKFW / RKAF byte layout, loader containers,
  worked extraction recipe, acceptance criteria.
- `backup-and-restore.md` - parameter and GPT parsing, sector arithmetic, export
  strategies, the three restore paths.
- `tool-config-format.md` - the `CFG\0` download config byte by byte, how to
  generate it, how to prove it, and the GUI traps that crash the tool.
- `pitfalls.md` - error messages, causes, and what to do; scripting traps.
- `case-legacy-rk3368.md` - the complete worked example (legacy RK3368-class box)
  with real numbers, including how the loader problem was found and proven.
- `case-modern-rk3328.md` - a second worked example (RK3318/RK3328 family,
  32 GB GPT, half-flashed device): how the chip was identified from U-Boot and
  the DTBO, the `0xCC` blank-partition evidence, and the config generation.
