# Backing up and restoring a Rockchip device

## 1. Reading the partition table from the device

### 1.1 Legacy boxes (RK3368 / RK330A, Android 5.x)

Sector 0 holds a `PARM` block: 4 bytes magic `PARM`, 4 bytes of header, then plain
text. Read it with

```
.\rk_tool.ps1 export 0 8192 sector0.img
```

and the text looks like:

```
FIRMWARE_VER: 5.1.0
MACHINE_MODEL: an RK3368-class device
MACHINE_ID: 007
MANUFACTURER: an RK3368-class device
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: 3368                      <- the SoC, authoritative
CHECK_MASK: 0x80
CMDLINE: console=ttyS2 ... mtdparts=rk29xxnand:0x00002000@0x00002000(uboot),0x00002000@0x00004000(trust),...
```

`MACHINE` / `MACHINE_MODEL` are the reliable identity. The `mtdparts` list is the
partition table: `size@start(name)`, in **sectors**.

The same text, minus the 8-byte `PARM` prefix, is the `parameter.txt` a firmware
package needs.

### 1.2 Modern boxes (RK3566 / RK3568, Android 11+) - GPT

Export 64 sectors and parse LBA 1 (`EFI PART`), little-endian:

| in GPT header | offset | meaning |
|---|---|---|
| MyLBA | 24 | 1 |
| AlternateLBA | 32 | last LBA; capacity = AlternateLBA + 1 |
| FirstUsableLBA | 40 | |
| LastUsableLBA | 48 | |
| PartitionEntryLBA | 72 | usually 2 |
| NumberOfEntries | 80 | usually 128 |
| SizeOfEntry | 84 | usually 128 |

Each entry: type GUID (0), first LBA (32), last LBA (40), name at 56 as UTF-16LE
(72 bytes). Entry `i` is at `PartitionEntryLBA*512 + i*SizeOfEntry`.

Reading the entry names is what reveals the *kind* of device: presence of
`super`, `dtbo`, `vbmeta`, `security` means Android 10+ dynamic partitions, so
there is **no standalone `system` partition** and the modify step is different.

Always derive capacity from the device. Two boxes of the same family were seen at
16 GiB and 58 GiB; reusing one's parameters on the other would have bricked it.

## 2. Exporting

### Naming convention (keep it, the tooling depends on it)

```
<name>_<START_SECTOR>-<SECTOR_COUNT>.img        both hex, decimal not allowed
uboot_00002000-00002000.img      start 0x2000   count 0x2000   -> 4,194,304 bytes
system_000B2000-00300000.img     start 0xB2000  count 0x300000 -> 1,610,612,736 bytes
```

**START is the first hex field, COUNT the second.** Swapping them makes every
cross-check report DIFFERENT except for partitions where start == count.

### Sizes and chunking

- expected bytes = count * 512; verify every file (see `verify_backup.ps1`)
- export big regions in ~2 GiB chunks and concatenate; a single huge export is
  more likely to be interrupted, and an interrupted export leaves a
  **right-sized file full of junk**
- always include **sector 0**. A restore that begins at 0x2000 leaves the IDBlock
  and parameter table untouched and cannot revive a dead box.

### `ReadLBA: Disable` / `device did not support to read`

This is a **capability reported by the device's loader**, not a cable problem:

- RKDevTool v3.x against an RK35xx returned `Error:ExportImageProc-->device did not
  support to read` for a range starting at sector 0, while small reads succeeded
- older AndroidTool v2.84 could not read that device at all

Before blaming the loader, confirm the ranges: a 64-sector read succeeding while a
multi-GB read fails is a capability limit, not a link error. Link errors look
different: `RKU_Write-->WriteFile failed,err=995`,
`RKU_ResetPipe-->DeviceIoControl failed,err=31`, `RKU_ReadCapability failed,err=-8`.

The worst variant of this is **silent**: nothing in the log, right-sized file, and
every byte past 32 MiB is `0xCC` because the device's U-Boot memsets it (see
`pitfalls.md`). That one is only caught by reading the bytes back, never by the
tool's exit status.

### Reading past 32 MiB: build a Maskrom loader (preferred fix)

The load being blocked is the **device's own U-Boot** rockusb read handler, so no
new host tool helps - RKDevTool, AndroidTool and rkdeveloptool all get the same
filler. The fix is to not use that U-Boot: run in **MASKROM**, where the host
uploads `usbplug` into DDR and *that* serves the USB reads (AndroidTool manual 1.9).
MASKROM needs a loader matching the chip, and `rkbin` builds one offline:

```
# RK3328's internal name is RK322H - do not look for "rk3328_usbplug"
bin/rk33/rk3328_ddr_333MHz_v1.22.bin        # DDR init  (CODE471 / FlashData)
bin/rk33/rk322xh_usbplug_v2.54.bin          # CODE472 - this is what reads flash
bin/rk33/rk322xh_miniloader_v2.50.bin       # FlashBoot
RKBOOT/RK3328MINIALL.ini                    # NAME=RK322H, [VERSION] 2.50
tools/boot_merger RKBOOT/RK3328MINIALL.ini  # -> rk3328_loader_v1.22.250.bin
```

- `rkbin/tools/boot_merger` is an **ELF**: run it from WSL, with the working
  directory at the rkbin root so the .ini's `bin/rk33/...` paths resolve
- `raw.githubusercontent.com` is unreachable on this network;
  `https://cdn.jsdelivr.net/gh/rockchip-linux/rkbin@master/<path>` serves single
  files and works
- self-check the output: `boot_merger ver 1.x` + `Info:Pack loader ok.`, file
  starts with the IDBlock magic `BOOT`, size ~180 KB, and the chip string appears
  **reversed** in the header (`RK3328` -> `322H`); entropy of the header ~4.9
  (a plain loader, unlike a signed/RC4 one at ~7.5)
- in MASKROM the tool needs this file in the **Loader download item** (manual 1.3);
  a mismatch reports `校验芯片失败` / `loader 与设备不匹配` (manual 2.3/2.4)
- if OTP secure boot is fused the BootROM rejects a self-built loader; that costs
  one power-cycle and changes nothing on the box

Writing a loader in MASKROM touches **RAM only** - no flash write happens until
you ask for one, so this step is safe on a working box.

Three things learned the hard way:

* MASKROM only accepts a loader while the **ROM** is in control. If a loader is
  already resident in DDR, `下载 Boot` silently does nothing. Re-enter MASKROM
  first (`进入Maskrom`); the tell that the ROM owns the device is that its PnP
  instance id loses the serial number (`USB\VID_2207&PID_xxxx\6&...` instead of
  `...\<SERIAL>`). After a successful download the serial comes back.
* The usbplug component carries the **same 32 MB guard** as U-Boot. Patch the
  `b.hs` in front of its `movz w1,#0xCC ; bl memset` pair (see `pitfalls.md`) and
  rebuild the loader with `boot_merger`; then MASKROM reads run past 32 MB.
* Post-patch, every **even-numbered 64 KiB block of a response is 0xCC filler**.
  Read the region twice, 64 KiB apart, merge per block, and verify with liblp's
  SHA256 trio plus the live `dm-*` sizes. `merge_super.py` + `lpverify.py` in the
  archive's `04_脚本` do exactly this for a `super` partition.

Whole-disk reads still come out of this trip as: real bytes, 0xCC filler in the
block parity, or neither - so always run a byte-level verdict (`checkread.py`)
before believing an export.

Alternatives when no loader can be built or accepted: **root inside the running
Android** (`dd` on `/dev/block/mmcblk*`, a kernel read - needs real root, see
`pitfalls.md` on `no_new_privs`), or accept per-partition backups of the ranges
the device does allow (sufficient for restore - see section 3).

## 3. Restoring - three paths, in order of preference

### A. `下载镜像` (per partition) - preferred, non-destructive

Load the parameter table, tick the partitions, flash. Verified working end to
end (`RunProc is ending, ret=1`). It does **not** touch the IDBlock, so it cannot
make things worse. Use the partition images directly.

### B. `升级固件` (firmware package) - convenient, rewrites the loader

One click for the whole set, at the cost of rewriting the loader/IDB region. Safe
when the package's loader matches the device (same model, same DDR config), and
recoverable because the original loader was backed up in the `uboot` partition
image. Requires a correctly built package - see `firmware-package-format.md`.

### C. `强制按地址写` with a full-disk image - last resort

For a bricked box (Maskrom). Write the whole-disk image starting at sector 0,
sector count = device capacity in sectors. If the tool warns that writing before
sector N will damage the IDB, **ignore it** - the image was read from sector 0 and
contains the IDBlock and parameter table; starting from 0 is exactly what a full
restore needs.

Prerequisite: the target's eMMC must be at least as large as the image. A smaller
eMMC truncates the write and can finish the bricking.

## 4. Verifying a backup set (do not skip)

```
.\verify_backup.ps1 -PartitionDir <dir> -FullDisk <full.img> `
                    -UserdataChunks <dir>\ud_*.img -UserdataStartSector 0x45C000 `
                    -WriteHashList <dir>\sha256.txt
```

Cross-checking the per-partition files against the full-disk image proves two
things at once: the two independent captures agree, and - when the ranges
together cover the image - there is no gap and no overlap.

Interpreting results:
- `misc`, `kpanic` being all zeros is normal (they are usually untouched)
- long all-zero runs inside `system` are unused ext4 space; they will also be
  zero in the standalone partition image, which is exactly what proves they are
  content, not a failed read
- a DIFFERENT result on **many** partitions usually means the parser is wrong,
  not the data. Re-check the naming convention before alarming anyone.

## 5. Archive checklist

Self-contained, or it is not a backup:

- [ ] every partition image + userdata chunks
- [ ] full-disk image (optional but the easiest whole-device restore)
- [ ] tool directories **and the Rockusb driver installer**
- [ ] a factory package of the same model (the loader source of last resort)
- [ ] docs: partition table, sector arithmetic, restore steps, `sha256.txt`
- [ ] a second copy on another physical disk
