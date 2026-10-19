# Worked example: legacy RK3368-class box — backup, system modification, working firmware package

A complete recorded run. Use it as a template; replace every device-specific
number with one you read from your own hardware.

## Device identity (read from sector 0, not assumed)

```
MACHINE_MODEL : RK3368-class box      MANUFACTURER : RK3368-class box
MACHINE_ID    : 007           MACHINE      : 3368      (RK3368 / RK330A)
FIRMWARE_VER  : 5.1.0         MAGIC        : 0x5041524B
capacity      : 30,769,152 sectors = 15,753,805,824 bytes (16 GiB eMMC)
```

Two lessons applied from the start: the model was confirmed from the flash rather
than the case label, and capacity was measured before assuming any address.

## Partition table (from the device's own `mtdparts`)

| # | name | start sector | count | bytes |
|---|---|---|---|---|
| 1 | reserved | 0x00000000 | 0x00002000 | 4,194,304 |
| 2 | uboot | 0x00002000 | 0x00002000 | 4,194,304 |
| 3 | trust | 0x00004000 | 0x00002000 | 4,194,304 |
| 4 | misc | 0x00006000 | 0x00002000 | 4,194,304 |
| 5 | resource | 0x00008000 | 0x00008000 | 16,777,216 |
| 6 | kernel | 0x00010000 | 0x00008000 | 16,777,216 |
| 7 | boot | 0x00018000 | 0x00010000 | 33,554,432 |
| 8 | recovery | 0x00028000 | 0x00010000 | 33,554,432 |
| 9 | backup | 0x00038000 | 0x00038000 | 117,440,512 |
| 10 | cache | 0x00070000 | 0x00040000 | 134,217,728 |
| 11 | kpanic | 0x000B0000 | 0x00002000 | 4,194,304 |
| 12 | system | 0x000B2000 | 0x00300000 | 1,610,612,736 |
| 13 | metadata | 0x003B2000 | 0x00008000 | 16,777,216 |
| 14 | baseparamer | 0x003BA000 | 0x00002000 | 4,194,304 |
| 15 | media | 0x003BC000 | 0x00080000 | 268,435,456 |
| 16 | radical_update | 0x0043C000 | 0x00020000 | 67,108,864 |
| 17 | userdata | 0x0045C000 | 0x018FC000 | 13,413,384,192 |

## Backups produced and verified

```
partitions\                 16 images, all sizes == count x 512, 0 mismatches
legacy_rk3368_ud_00..06.img userdata, 6 x 2 GiB + 1 x 504 MiB
legacy_rk3368_full_disk.img 15,753,805,824 bytes
                           SHA256 39740964EE4D81773FD60559187EF7618F923386CD3CD8B080A02C3A964E3AA9
```

Verification performed (see `verify_backup.ps1`):

- size check on all 16 partition images — 16/16 OK
- cross-check each partition image against the full-disk image at its offset —
  **16/16 IDENTICAL**
- cross-check all 7 userdata chunks — **7/7 IDENTICAL**, and the last chunk ends
  exactly at the image size, so the two captures together cover the whole disk
  with no gap and no overlap
- SHA256 of the full-disk image recomputed and matched the recorded value

Observation worth keeping: `cache` and `backup` are all zeros and `system`
contains ~1.2 GB of zero runs (unused ext4 space). All of it is equally zero in
the standalone partition images, which is what proves it is genuine content
rather than a failed read.

## System variants

| image | markers found | meaning |
|---|---|---|
| stock `system_000B2000-00300000.img` | stock launcher only | factory system, untouched |
| `system_modified.img` | Emotn 11, dangbei 4, 应用管家 1 | early modified build; this one was actually flashed and verified on the device |
| `system_final.img` | Emotn 11, dangbei 17, 当贝 3, 应用管家 1 | complete modified build (EmotnUI + 当贝市场 + 应用管家) — used in the firmware packages |

Markers were obtained with `scan_markers.py`; the stock image is what makes the
comparison meaningful. Note the two modified images are genuinely different
(different SHA256) — do not deduplicate them without asking.

## The firmware package: what failed, and what fixed it

Ten attempts failed on import. All the surface variables were swept:

| variable | values tried | result |
|---|---|---|
| loader | device's own `uboot.img` (4,194,304, `LOADER  `) | failed |
| | rkbin `rk3368_miniloader_v2.58.bin` (117,700, `RSAK`) | failed |
| | rkbin `rk3368_usbplug_v2.58.bin` (82,692, `RSAK`) | failed |
| | rkbin `rk3368_ddr_600MHz_v2.06.bin` (18,972, `RK33:`) | failed |
| packer | RKImageMaker ver 2.23 / ver 1.67 | failed |
| RKAF builder | AFPTool v2.28 / v1.65 | failed |
| `-os_type` | ANDROIDOS / ANDROID / LINUXOS / DHARAOS / LITEOS / none | failed |
| tool | RKDevTool v3.37 (`err=-9`) / AndroidTool v2.84 (`err=-2009`) | failed |
| size | 12 MB / 16.7 MB / 1.54 GB / 2.34 GB | failed |

Every one of those used a **single component** or the wrong container as the
loader. The fix came from a different direction: take a factory firmware image of
the same model and extract its loader.

```
reference : rk3368_factory_firmware_20170503.img   (538,597,848 bytes)
header    : [29..32] = 219,470   [33..36] = 219,572
extracted : rk3368_loader_official.bin  219,470 bytes
            magic "BOOT"
            items: RK3368_DDR_800M_V1.x / FlashBoot / rk3368usbplug
            SHA256 9987D7A2F15EE0646650AEBD953ED3DE8BD2608E56AA0F975CD873ADB4CE3688
```

Packages built with it (both toolchains) imported successfully on the first try.

An independent confirmation came from a coincidence worth noting: the three rkbin
components summed to 219,364 bytes (18,972 + 117,700 + 82,692), i.e. the official
loader is essentially those three parts plus ~106 bytes of framing — which is
exactly what "combined container" means.

## Final artifacts

```
legacy_rk3368_full_disk.img       15,753,805,824  whole-disk image, verified
partitions\*                      16 partition images, verified
system_final.img / system_modified.img       two modified system builds
pack_3368\                        pack dir: package-file, parameter.txt, loader, images
legacy_rk3368_off_ldr_v167.img       231,150,040    lean package (no system) — proves the loader
legacy_rk3368_full_v167.img        1,841,764,824   full package, AndroidTool v2.84 toolchain
legacy_rk3368_full_v223.img        1,841,746,392   full package, RKDevTool v3.37 toolchain
```

All four packages share the same loader region hash as the factory package —
which is the strongest single statement that the loader problem is solved.

Naming note: file names drift between the parameter block's chip id and whatever
retail name the box carries. The hashes and header values above stay valid
regardless — always read the actual file names rather than trusting a tutorial
written earlier.

## Reusable commands

```
# backup verification (sizes + cross-check + hash list)
.\verify_backup.ps1 -PartitionDir .\partitions -FullDisk .\legacy_rk3368_full_disk.img -WriteHashList .\sha256.txt

# rebuild a package after swapping the system image (only system.img changes)
.\build_firmware.ps1 -PackDir .\pack_3368 -Loader .\pack_3368\RK3368MiniLoaderAll_V2.30.bin `
                     -OutFile .\legacy_rk3368_full_v167.img `
                     -ToolBin 'D:\...\Rockchip-AndroidTool_Release_v2.84\bin' `
                     -ReferenceLoader .\rkbin\rk3368_loader_official.bin

# what is inside each system image
python scan_markers.py .\partitions\system_000B2000-00300000.img .\system_final.img
```

## Remaining gap in that archive

The tool directories and the Rockusb driver were collected into the archive, but
the archive still had no second physical copy. An archive on one disk is one
disk failure away from being no archive. Check this every time.
