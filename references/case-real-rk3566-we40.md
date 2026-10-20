# Worked example 3 - RK3566 TV box (WE40 / WE60Pro / W40 family), Android 11+, GPT + dynamic `super`

A third complete run, on the **RK3566** boxes this project is actually built around
(WE40 / WE60Pro / W40). The procedure below is exactly what `scripts/` + `tools/`
deliver; the LBA / size numbers are the typical shape of this family and **must be
replaced by the values the RKDevTool "设备分区表" panel reports for the specific unit**
(see the trap about trusting case numbers at the end).

## Identity (read-only, from the device)

| item | value | how it was obtained |
|---|---|---|
| SoC | Rockchip RK3566 (quad A55, 64-bit) | U-Boot `cpu=rk3566`, `model=Rockchip RK3566`; DTBO bootarg `androidboot.boot_devices=fe310000.sdhci` (0xfe3xxxxx = RK35xx generation) |
| USB | `VID_2207` & `PID_350B` (Loader) / `PID_350A` (MASKROM), serial from `Get-PnpDevice` | tool status bar `发现一个LOADER设备` |
| eMMC | ~61,000,000 sectors ≈ 29–31 GiB (32 GB class) | GPT `AlternateLBA` |
| table | GPT, ~14–16 partitions, both GPT CRCs valid | LBA1 `EFI PART` |
| U-Boot | `U-Boot 2017.09 (Apr 2024)` | `uboot` partition strings |
| loader | combined `MiniLoaderAll.bin`, ~480 KiB (`RK3566MiniLoaderAll.bin` in `rkbin/`) | carved out of the first 0x2000 sectors at Step 0 |

> **RK3566 ≠ RK3368 loader.** The RK3566 loader is a **combined container** built by
> `boot_merger` from `rkbin/RKBOOT/RK356xMINIALL.ini`. A single `rk3566_ddr_*.bin` or
> `usbplug` component will fail import with `Loading loader failed err=-9`. The
> 219,470-byte `BOOT` magic from the RK3368 example does **not** apply here.

## Step 0 — back up partition table + loader FIRST (non-negotiable)

```
# dump the first 0x2000 sectors (covers GPT + loader region)
python scripts/extract_sectors.py \\.\PhysicalDriveN 0 0x2000 we40_step0.bin
# carve the combined loader out of it
python scripts/carve_loader.py we40_step0.bin RK3566MiniLoaderAll.bin
```
The loader region is the bytes right after the 102-byte RKFW header when read from a
factory `update.img`; from live flash it sits before the GPT (LBA 64 / sector 0x40 on
most RK356x). Never proceed without `RK3566MiniLoaderAll.bin` safely copied off-box.

## Partition table (typical RK3566 / Android 11 shape)

```
 idx  name          start(LBA)     size(sectors)   size
  0   uboot         0x00004000      0x00002000       4 MiB
  1   trust         0x00006000      0x00002000       4 MiB
  2   misc          0x00008000      0x00000800       1 MiB
  3   resource      0x00008800      0x00010000      32 MiB
  4   boot          0x00018800      0x00010000      32 MiB
  5   recovery      0x00028800      0x00030000      96 MiB
  6   backup        0x00058800      0x000C0000     384 MiB
  7   security      0x000B8800      0x00000800       1 MiB
  8   dtbo          0x000B9000      0x00002000       4 MiB
  9   vbmeta        0x000BB000      0x00000800       1 MiB
 10   metadata      0x000BB800      0x00008000      16 MiB
 11   baseparameter 0x000C3800      0x00000800       1 MiB
 12   super         0x000C4000      0x00C00000     ~3.2 GiB   (system/vendor/product/odm live here)
 13   userdata      0x00CC4000      (rest)         ~25 GiB
 (+ loader from sector 0x40, GPT at LBA1, backup GPT at AlternateLBA)
```
**No standalone `system`** — it is inside `super` as a logical partition. Same rule as
the RK3328 example; RK3566 just has a different partition set around `super`.

## Full backup + tool config

* per-partition images → `01_备份镜像\partitions\` (everything below `super`).
* `super` (~3.2 GiB) and `userdata` (~25 GiB) dumped with
  `scripts/append_export.ps1` in 1 GiB chunks (the box's eMMC cannot hold two copies).
* tool config generated from a spec (`scripts/rk_config.py make spec.csv config.cfg 1`)
  after `rk_config.py selftest` reproduces a known-good config byte-for-byte; **then
  add the `super` and `userdata` rows** so the config is a complete backup, not a
  partial one.
* verify visually: launch `tools/RKDevTool_v3.37/RKDevTool.exe -WorkingDirectory
  <tool dir>`, screenshot the 下载镜像 page — all rows ticked, paths point at the
  archive.

## Verification

1. GPT header CRC32 and entry-array CRC32 recalculated and equal (first 34 sectors
   byte-exact).
2. cross-check: every below-`super` partition identical between the per-partition export
   and an independent continuous capture (`scripts/verify_backup.ps1`).
3. `super` read with the **two-pass merge** method from `case-modern-rk3328.md` if any
   range comes back as `0xCC` filler — RK3566's Rockusb read guard has the same
   `memset(buf,0xcc,...)` behaviour, so a single export can lie. Merge two exports 64 KiB
   apart (`scripts/merge_two.py`) before trusting `super`.
4. liblp self-check: `scripts/lpverify.py super.img` prints geometry/header/table SHA256
   and the five logical extents (system / system_ext / vendor / product / odm) — compare
   against live `dm-0..dm-4` sizes.

## Modifying the system inside `super` (in place, no lpunpack/lpmake)

Identical recipe to the RK3328 example, repeated here because it is the whole point:

1. carve `system`'s ext4 along its LP extent (`scripts/lpverify.py` gives the byte
   range; extent 0 is linear).
2. copy the image **into WSL** (`/root/img`, not `/mnt/d` — drvfs mounts give an empty
   dir) and `mount -o loop,rw`. If the fs reports `shared_blocks`, use `debugfs` instead
   of a rw mount.
3. edit: `rm -rf` the bloat app dirs, then `cp` replacement APKs **over the existing
   files** so the inode and its `security.selinux` label (`u:object_r:system_file:s0`)
   survive. Reuse an inode; never create brand-new files for apps or they stay unlabelled.
4. splice back to the same offset in `super`. liblp's three SHA256 sums stay identical
   because metadata is untouched — that is why in-place edit beats rebuild.
5. fingerprint check: `scripts/scan_markers.py stock.img mod.img` and report the delta
   (launcher count, market count, helper-app count). Always intersect any blacklist
   with what the image *actually* contains.

## Re-packaging with the bundled tools

```
# default -ToolBin already points at the modern toolchain
.\scripts\build_firmware.ps1 -PackDir D:\we40\pack -Loader D:\we40\RK3566MiniLoaderAll.bin `
                              -OutFile D:\we40\update.img -ReferenceLoader D:\we40\known_good_loader.bin
```
* loader **must** be the combined container (Step 0 carve).
* small-package first: omit `system` from `package-file`, build, and import in RKDevTool
  — the loader digest check fires before content is read, so a 30-second import proves
  the loader in seconds.
* acceptance: assert RKFW header `u16@4 == 102`, `u32@29 == loaderLen`,
  `u32@33 == 102+loaderLen`; if a known-good package exists, SHA256 of the loader region
  (`image[102:102+loaderLen]`) must match it.

## Archive (self-contained)

`02_归档\` = partition images + `RK3566MiniLoaderAll.bin` + `config.cfg` +
`tools/` (or a note pointing at it) + `scripts/` + this doc + a factory reference
`update.img` + `sha256.txt`. Copy to a **second physical disk**.

## Traps specific to RK3566

* **Case numbers are not your device's numbers.** The LBA table above is the family
  shape; a WE40 and a W40 differ in `super`/`userdata` boundaries. Always read the real
  table from RKDevTool before acting. The RK3328/RK3368 examples are different SoCs
  entirely — do not copy their loader size or partition set.
* launching RKDevTool from a different working directory silently loads a different
  `config.cfg` (rule 13 in SKILL.md) — always pass `-WorkingDirectory <tool dir>`.
* PowerShell 5.1 reads BOM-less scripts with Chinese paths as ANSI — add a UTF-8 BOM to
  every `plan_*.txt` / script you write, or paths become "not found".
* `0xCC` filler on a single-pass `super` read is a reader artifact, not blank flash —
  merge two 64-KiB-offset exports before concluding anything about `super`.
