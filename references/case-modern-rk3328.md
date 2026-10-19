# Worked example 2 - RK3318/RK3328 family, 32 GB GPT, half-flashed device

A second complete run of the pipeline, this time on a modern GPT box with dynamic
partitions. Numbers are from the device, not from any SDK.

## Identity (read-only, from the device)

| item | value | how it was obtained |
|---|---|---|
| SoC | RK3318 / RK3328 family (32-bit-era addresses) | U-Boot strings `board=evb_rk3328`, `board_name=evb_rk3328`, `Rockchip RK3318 EVB avb`, runtime `soc is rk3318`; DTBO bootarg `androidboot.boot_devices=ff520000.dwmmc` (0xff5xxxxx = that generation, RK35xx use `sdhci@fe310000`) |
| USB | `VID_2207 & PID_320C`, serial `the device serial` | `Get-PnpDevice` + tool status bar `发现一个LOADER设备` |
| eMMC | 61,063,168 sectors = 31,264,342,016 B = 29.12 GiB (32 GB) | GPT `AlternateLBA` = 61,063,167 |
| table | GPT, 15 partitions | LBA1 `EFI PART`, both GPT CRCs valid |
| U-Boot | `U-Boot 2017.09 #anman.zhou (Nov 02 2023 - 10:56:31 +0800)` | `uboot` partition strings |
| boot | kernel 31,238,160 B, ramdisk 824,336 B, second 4,278,272 B, page 2048 | Android boot header |

The tool's own reader agreed with all of it: 设备分区表 on the 下载镜像 page printed
`Partition is gpt` plus the same 15 rows (LBA / Size / Name). That panel is worth
pressing early - it is the cheapest cross-check of a hand-decoded table.

## Partition table

```
 0 security      0x00002000  0x00002000     1 uboot    0x00004000 0x00002000
 2 trust         0x00006000  0x00002000     3 misc     0x00008000 0x00002000
 4 dtbo          0x0000A000  0x00002000     5 vbmeta   0x0000C000 0x00000800
 6 boot          0x0000C800  0x00014000     7 recovery 0x00020800 0x00030000
 8 backup        0x00050800  0x000C0000     9 cache    0x00110800 0x000C0000
10 metadata      0x001D0800  0x00008000    11 baseparameter 0x001D8800 0x00000800
12 logo          0x001D9000  0x00008000    13 super    0x001E1000 0x00614000
14 userdata      0x007F5000  0x03246FDF    (+ GPT 0x0..0x21, loader from 0x40)
```

Note there is **no standalone `system`**: on an Android 10+ box system/vendor/
product live inside `super`. Anyone asking "why is there no system partition"
should be shown this.

## What was actually on the device

Only the boot chain exists. Everything else reads back as filler:

| partition | content seen |
|---|---|
| security / uboot / trust / misc / dtbo / vbmeta / boot | real (loader is encrypted high-entropy; vbmeta effectively empty - 3 non-zero bytes) |
| recovery, backup, cache, metadata, baseparameter, logo | `0xCC` 100% |
| super (3.26 GB) | `0xCC` 100% (1 GiB read at its start = 1 distinct byte; no LP magic `D9 5E C6 67`; +2 more samples) |
| userdata (27 GB) | `0xCC` 100% (4 samples) |
| disk tail (backup GPT) | `0xCC` - the device has no backup GPT |
| `misc` BCB | `boot-recovery` / `recovery` / `--wipe_all` |

`0xCC` is a write filler, not a read failure: one continuous 1 GiB capture
contained real code, `0x00` padding and `0xCC` filler side by side, and 18/18
overlapping ranges matched a second, independent capture byte for byte.

**Consequence:** the box cannot boot Android, and "remove the vendor services and
swap the launcher" has nothing to act on until a system image is supplied. Say
that plainly instead of searching the operator's disk for a ROM.

## Verification used

1. GPT header CRC32 (`0x2587DE14`) and entry-array CRC32 (`0xB3BE76AD`) both
   recalculated and equal - proof the first 34 sectors are byte-exact.
2. 18/18 cross-check: all 14 partition images identical to a separate continuous
   1 GiB capture, plus head-32-MiB and two boundary captures.
3. Size check via `verify_backup.ps1` (14/14 OK).
4. Blank regions: 7 x 16 MiB samples, all 100% `0xCC`; equal-size all-`0xCC`
   files hash identically, which the archive shows three times.

## Backup and config production

* partition images per partition into `01_备份镜像\partitions\`
* `super` (3.04 GiB) and `userdata` (25.1 GiB) dumped afterwards with
  `append_export.ps1` in 1 GiB chunks (peak = target + one chunk) because the disk
  could not hold two copies
* tool config generated from a spec (`rk_config.py make spec.csv config.cfg 1`,
  storage 1 = EMMC) after `rk_config.py selftest` reproduced two files the tool
  itself had written, byte for byte
* confirmed visually: started the tool with `-WorkingDirectory <tool dir>` and
  screenshotted the 下载镜像 page - all 14 rows ticked, addresses `0x00000000`,
  `0x00002000`, ... `0x001D9000`, each path pointing at the archive
* **then added `super` and `userdata` rows to the config** (no image yet at the
  time) - the first config shipped without them and the owner read that as an
  incomplete backup, which was correct

## Traps hit here

* launching the tool from another directory silently loaded a *different*
  `config.cfg` and looked like a rejected config (see rule 13 in SKILL.md)
* `TCM_GETITEMRECT` sent from PowerShell with a `ref`-struct DllImport bound to
  the `IntPtr` overload → wild `lParam` → the tool crashed in `COMCTL32.dll`
  (0xc0000005 / 0xc000041d at 0x2cac4), twice
* PowerShell 5.1 read BOM-less scripts with Chinese paths as ANSI - every path in
  `plan_*.txt` and `crosscheck.ps1` became "not found" until the BOM was added

## CORRECTION (2026-10-14) - the "half-flashed device" conclusion was wrong

Everything under "What was actually on the device" was an artifact of the read
path, not a fact about the box. The box boots Android 11; its flash was never
blank. Two things were wrong: a filler byte was read as content, and a magic
number was looked up incorrectly.

* Same LBAs came back real or `0xCC` **depending on the request**: in one 1 MiB
  export the even 64 KiB blocks were `0xCC` and the odd ones real; the very same
  range was real when the export started 64 KiB earlier. Flash cannot do that, a
  reader's filler can.
* Mechanism: Rockchip's Rockusb read handler runs
  `if ((blkstart + blkcnt) > RKUSB_READ_LIMIT_ADDR) { memset(buf, 0xcc, blkcnt *
  512); return blkcnt; }` - a *successful* return, nothing in the log. U-Boot does
  it (`u-boot/cmd/rockusb.c`, documented by the xrock project) and so does the
  MASKROM `usbplug` (`00A10C movz w1,#0xCC` + `bl memset`).
* What it took to read the flash: MASKROM with a self-built loader whose guard was
  NOPed (`rk322xh_usbplug_v2.54.bin`, `00A0BC: 42 02 00 54` -> `1F 20 03 D5`,
  `scripts/patch_usbplug.py`), then **two exports 64 KiB apart merged block by
  block** (`scripts/merge_two.py`) - A and B each supplied 24,896 of super's
  49,792 blocks and **zero blocks were filler in both**.
* Proof, without any reference image: liblp's own three SHA256 checksums
  (geometry / header / tables) all matched, and super's five logical partitions'
  extents matched the live `dm-0..dm-4` sizes exactly (system 1133.6, system_ext
  42.6, vendor 146.9, product 140.5, odm 0.5 MB).
* The LP magics are `0x616C4467` (geometry @4096) and `0x414C5030` (header, slot 0
  @12288, slots spaced by `metadata_max_size`). `0xD95EC667` was a mistake - which
  is exactly why the old "no LP magic" search found nothing. Descriptor offsets in
  the header are relative to the header's *end*.
* Also corrected: `recovery` is 96 MB (not 42) and `backup` is 384 MB (not 4), and
  `cache` / `metadata` / `baseparameter` had been left out of the table entirely.

Final archive: all 15 partition images, 4,074 MB, hashes in
`03_文档\_hashes_partitions.txt`; `boot` / `recovery` / `super` / `backup` /
`cache` / `metadata` / `baseparameter` / `logo` re-dumped with the two-pass method,
the below-32-MiB partitions were already correct, and `userdata` (27 GB) was
deliberately skipped.

### Modifying the system inside this `super` - done and verified (2026-10-14)

Recipe that worked on this box (no lpunpack/lpmake, no flash rebuild):

1. carve `system`'s ext4 out of `super` along its LP extent (extent 0 is linear,
   `target_sector=2048`, so the file lives at byte 0x100000, length
   1,188,614,144) - `scripts/extract_logical.py`
2. copy that image **into the WSL filesystem** and `mount -o loop,rw` it. Mounting
   straight from `/mnt/d` (drvfs) silently gives an *empty* directory; copy to
   `/root/img` first. This fs has **no `shared_blocks`** (features: ext_attr
   dir_index filetype extent sparse_super large_file huge_file uninit_bg dir_nlink
   extra_isize), so rw mounting works. It is 99.7% full, so delete before adding.
3. edit: `rm -rf` the app dirs, then `cp` the replacement APKs **over the existing
   files** - `cp` onto an existing path truncates and rewrites, so the **inode and
   its `security.selinux` label survive** (`u:object_r:system_file:s0`; verify with
   `os.getxattr` from Python under WSL, which can read it as root). `mv` for
   renames keeps the inode too. Creating *new* files instead would leave them
   unlabelled - reuse an inode whenever a new app must be added.
4. splice back: `dd if=system_rw.img of=super_copy.img bs=1M seek=1 conv=notrunc`
   then prove it by re-extracting the logical partition from the new `super` and
   `cmp`-ing against the edited image. liblp's three SHA256 sums stay identical
   because the metadata is never touched - which is the whole point of editing in
   place rather than rebuilding.

Fingerprint check (`scripts/scan_markers.py old.img new.img`), stock -> modified:
`Emotn 0->13`, `dangbei 6->23`, `当贝 0->3`, `应用管家 0->1`, `stock launcher 294->282`.
Only 6 app dirs existed from a 200-entry package blacklist - this box carries no
`com.yunos.*` / `com.alibaba.*` at all, so the list must always be intersected
with what the image really contains before promising a "de-bloated" system.

### Modifying the system inside this `super` (no lpunpack/lpmake on hand)

`super`'s logical partitions are plain linear extents, so the filesystem is edited
**in place**: parse the extents (`scripts/lpverify.py` gives them), carve
`system`'s byte range out of `super`, edit that ext4 with `debugfs` (WSL has
`e2fsprogs`; `shared_blocks` images cannot be mounted rw but `debugfs` edits them
fine), then write the range back to the same offset. The LP metadata is never
touched, so there is nothing to rebuild - and nothing to get wrong in a rebuild.
