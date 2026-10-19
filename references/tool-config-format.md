# The RKDevTool image-download config (partition-table config)

A partition-image backup is **half a restore kit** without this file. The
"下载镜像" page needs one row per partition - start sector plus the image file -
and a row list that has to be typed by hand is where restores go wrong. RKDevTool
keeps that list in a binary file whose magic is `CFG\0`, and it loads the file at
startup, so generating it turns a restore into "load the config, press 执行".

## 1. Where the tool reads it from

`config.ini` says `DEFAULT_IMAGE_CONFIG=config.cfg`, a **relative** path, and the
tool resolves it against its **current working directory** - not against the
folder the exe lives in. Consequence, observed the hard way:

* launch `RKDevTool.exe` from `C:\x\` and it loads `C:\x\config.cfg`, silently
  ignoring the nice config that sits next to the exe;
* the 下载镜像 page then shows some earlier, unrelated row list and it looks as if
  the generated file was rejected.

So: put `config.cfg` next to the exe **and start the tool with that folder as the
working directory** (`Start-Process -FilePath <exe> -WorkingDirectory <dir>`), or
load an absolute path explicitly with 加载分区表.

The file is also **not** re-saved on exit. A round trip through the GUI therefore
cannot be used as a check; use `rk_config.py selftest` and a screenshot instead.

## 2. File layout (confirmed against files the tool wrote itself)

Header, 29 bytes:

| offset | size | content |
|---|---|---|
| 0 | 4 | `CFG\0` |
| 4 | 2 | u16 29 - header size |
| 6 | 2 | u16 year |
| 8 | 2 | u16 month |
| 10 | 2 | u16 **storage type, 0-based**: 0 FLASH, 1 EMMC, 2 SD, 3 SD1, 4 SPINOR, 5 SPINAND, 6 RAM, 7 USB, 8 SATA, 9 PCIE, 10 UFS, 11 RVD |
| 12 | 2 | u16 day |
| 14 | 2 | u16 hour |
| 16 | 2 | u16 minute |
| 18 | 2 | u16 second |
| 20 | 2 | u16 millisecond |
| 22 | 1 | u8 row count |
| 23 | 1 | u8 29 |
| 24 | 3 | `00 00 00` |
| 27 | 2 | `62 02` |

Then `count` records of **610 bytes** each: `62 02` (u16 610, little endian)
followed by a 608-byte payload:

| payload offset | size | content |
|---|---|---|
| 0 | 64 | name, UTF-16LE, 32 chars |
| 64 | 16 | zero in every sample |
| 80 | 512 | image path, UTF-16LE, 256 chars |
| 592 | 4 | u32 size in **128 KiB units** = ceil(sector_count / 256) |
| 596 | 4 | zero |
| 600 | 4 | u32 **start sector** |
| 604 | 4 | u32 flags, bit0 = row ticked (only ticked rows are written) |

File size is exactly `29 + 610 * count` - a quick sanity check.

Two quirks worth knowing:

* **payload byte 591** is `00` in every file this tool version wrote for an eMMC
  box, but `02` / `33` / `FF` in a few configs produced by other SDK generations.
  It is not the tick flag and not part of the path (the path starts at an even
  offset, so odd bytes cannot be one of its UTF-16 code units). `rk_config.py`
  writes 0, which is what the target version reads.
* several **chip templates** in an SDK (`rk3328-config.cfg`, `rk3568-config.cfg`)
  look like this format but are not: they decode to garbage, so never use them as
  a schema reference - only use files the tool itself saved.

## 3. Generating it

```
python -X utf8 scripts/rk_config.py make <spec.csv> <out.cfg> [storage]
```

`spec.csv`, one row per partition, `#` comments allowed:

```
name,start_sector,count_sectors[,image_path]
reserved,0x00000000,0x00002000,D:\archive\01_备份镜像\partitions\reserved_00000000-00002000.img
super,0x001E1000,0x00614000,
```

A row with no `image_path` is written **unticked**, which is how a partition that
has no image (an unwritten or deliberately skipped one) can still be listed
without the tool trying to write it.

`storage` defaults to 1 (EMMC). Pass 4 for a SPI-NOR board, etc.

## 4. Proving the file is right (do not skip)

1. **Byte-exact rebuild of the tool's own output** - the writer reproduces real
   files bit for bit:

   ```
   python -X utf8 scripts/rk_config.py selftest <known_good.cfg>
   python -X utf8 scripts/rk_config.py dump <generated.cfg>
   ```

   Run `selftest` on at least one config the tool wrote for the same box type
   (an eMMC/an RK3368-class device-style file and an 18-row file were both byte-identical here).
2. **Visual check** - start the tool with the config as its working-directory
   `config.cfg`, switch to 下载镜像 and screenshot the window: every row shows its
   address, name and path. `shot.ps1` (or a small PrintWindow wrapper) is enough;
   the grid is custom-drawn, so `GetWindowText` cannot read it.
3. Compare the row list with the device's own partition table, which the tool
   prints itself: press **设备分区表** on the 下载镜像 page and read the panel
   (`Partition is gpt`, then NO / LBA / Size / Name). That panel is the cheapest
   independent oracle for start sectors and sizes, and it also tells you whether
   a `super` partition exists at all.

### Pitfall that crashed the tool twice

Do **not** send `TCM_GETITEMRECT` to the tab control from PowerShell with a
`ref`-struct DllImport: the overload binds to the `IntPtr` one, `lParam` becomes a
wild pointer and the tab control writes 16 bytes to it - `RKDevTool.exe` died in
`COMCTL32.dll` (0xc0000005 / 0xc000041d at 0x2cac4) both times. Also never click a
`SysTabControl32` that reports 0 items. If a tab must be selected, take the
coordinates from the control's own geometry (the strip is left-aligned, ~55 px per
tab in this build) after checking `TCM_GETITEMCOUNT > 0`.
