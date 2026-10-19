# Rockchip firmware package format (RKFW / RKAF) and loaders

Everything here was derived by parsing real packages byte by byte. Treat the
numbers as **observed**, not as a specification: verify against your own
known-good package before trusting any constant.

## 1. Outer container: RKFW

`update.img` is an RKFW container. Layout (little-endian, 32-bit tools):

| offset | size | meaning | RK3368 factory sample |
|---|---|---|---|
| 0 | 4 | magic `52 4B 46 57` = `RKFW` | `RKFW` |
| 4 | 2 | header length (always 102) | `66 00` = 102 |
| 8 | 2 | version-ish field | `00 05` (1280) |
| 10 | 2 | image/os-type field | `00 00` |
| 12 | 2 | another version field | `06 01` (262) |
| 14 | 2 | build year | `E1 07` = 2017 |
| 16 | 5 | build date+time (y,m,d,h,min) | `05 03 10 09 1D` |
| 21 | 4 | vendor/chip tag, ASCII, space-padded | `A033` |
| 25 | 4 | header length again | 102 |
| **29** | **4** | **loader size** | **219,470** |
| **33** | **4** | **image offset = 102 + loader size** | **219,572** |
| 45..101 | | zero in every package seen | |

Then directly: **the loader** (length from offset 29), then **the RKAF**.

The two bold fields are the whole acceptance test. For the RK3368 factory loader:

```
u32 @ 29 == 219470            (equals the loader file's own size)
u32 @ 33 == 219572            (== 102 + 219470)
```

Failed packages in the recorded session had `4194304 / 4194406` and
`117700 / 117802` - visible at a glance.

## 2. Inner container: RKAF

Immediately after the loader. Header (first 0x800 bytes hold metadata):

| offset | content |
|---|---|
| 0 | `52 4B 41 46` = `RKAF` |
| 4 | total size |
| 8 | machine id string, prefixed by a space, e.g. ` VAL_3368` / ` 007` |
| 0x48 | chip string, e.g. ` RK3368` |
| 0x8C.. | **item table**: pairs of fixed-stride strings - logical name, then path |
| 0x800.. | an embedded copy of the `package-file` text |
| ... | file data, 512-byte aligned |

Item table as seen in the RK3368 factory package (readable as ASCII strings):

```
package-file  package-file
bootloader    RK3368MiniLoaderAll_V2.30.bin      <- the loader, inserted under its own file name
parameter     parameter.txt
uboot         Image/uboot.img
trust         Image/trust.img
misc          Image/misc.img
resource      Image/resource.img
kernel        Image/kernel.img
boot          Image/boot.img
recovery      Image/recovery.img
system        Image/system.img
backup        RESERVED
#update-script  update-script
#recover-script recover-script
```

Practical consequence: `RKImageMaker` puts the loader **both** into the RKFW
header region and into the RKAF as the `bootloader` item. Both copies are the
same bytes in the factory package.

## 3. Loaders - the part that decides everything

A packaging loader is a **container embedding three parts**:

```
DDR init  +  FlashBoot (SPL / miniloader)  +  usbplug
```

Container magics observed:

| magic | what it is | usable as the packaging loader |
|---|---|---|
| `BOOT` | combined container built by rockchip's `boot_merger` | **yes** - this is the one |
| `LDR ` | combined container, newer toolchains (RK356x SDK) | yes |
| `LOADER  ` | on-flash form found in a device's `uboot`/loader region | no |
| `RKNS` | on-flash loader container (RK356x) | no |
| `RSAK` | a single signed component (`miniloader`, `usbplug`) | **no** |
| `RK33:` | a single component (DDR bin) | **no** |

Verified RK3368 case: the correct loader is a **219,470-byte `BOOT` container**
whose internal item names read `RK3368_DDR_800M_V1.x`, `FlashBoot`,
`rk3368usbplug`. Note the DDR speed: the factory build used **800M** while
rockchip's current `RKBOOT/RK3368MINIALL.ini` recipe names a **600M** DDR
component. The DDR component must match the board's DRAM; when repackaging for a
device you already own, prefer the container that matches that device.

### 3.1 Extracting a loader from a factory package

The most reliable source for a new model. Read the RKFW header, then copy:

```
offset = 102
length = u32 LE @ 29
```

Verify by checking that `u32 @ 33 == 102 + length`, then hash the region and keep
it as the reference for all later packages of that model.

### 3.2 Building a loader with rockchip's own tool

`rkbin` ships the recipe and a merger:

```
RKBOOT/RK3368MINIALL.ini        (recipe: exact component paths + output name)
bin/rk33/rk3368_ddr_*.bin
bin/rk33/rk3368_miniloader_*.bin
bin/rk33/rk3368_usbplug_*.bin
tools/boot_merger               (Linux ELF - run it under WSL)

cd <rkbin> && ./tools/boot_merger RKBOOT/RK3368MINIALL.ini
```

Notes: fetch rkbin files through `raw.githubusercontent.com` (the GitHub API and
jsDelivr may be rate-limited/403 on a given network); the `[OUTPUT] PATH=` entry
names the produced file; `boot_merger` resolves the ini's relative paths from the
current directory, so keep the `bin/<family>/...` tree intact.

## 4. Packaging commands

```
AFPTool      -pack  <packDir> <out.rkaf>
RKImageMaker -RK33  <loader> <rkaf> <out.img> -os_type:ANDROIDOS
```

`packDir` must contain `package-file`, `parameter.txt` and the images. Mirror a
factory package's `package-file`. A minimal, working `package-file`:

```
# NAME          Relative path
#HWDEF          HWDEF
package-file    package-file
bootloader      RK3368MiniLoaderAll_V2.30.bin
parameter       parameter.txt
uboot           uboot.img
trust           trust.img
misc            misc.img
resource        resource.img
kernel          kernel.img
boot            boot.img
recovery        recovery.img
system          system.img
backup          backup.img
```

`-os_type` is only meaningful to the v2.84-era `RKImageMaker` (ver 1.67), which
rejects anything but `ANDROIDOS`. The v3.37-era one (ver 2.23) accepts the flag
but writes a different value into the header and still produces a package that
imports. Build with the generation that matches the tool you will flash with.

## 5. Toolchain pairs and their header differences

| tool pair | AFPTool | RKImageMaker | RKFW fields `[8..15]` | RKAF entry flags |
|---|---|---|---|---|
| AndroidTool v2.84 | v1.65 | ver 1.67 | `01 05 07 00 06 01 <year>` | `userspace=0x801`, no `flash_address` |
| RKDevTool v3.37 | v2.28 | ver 2.23 | `01 05 00 00 00 02 <year>` | `userspace=0x800`, `flash_address=...`, entries shifted by 0x1800 |

Both generations produced importable packages in the recorded session; the
loader was the only real blocker. Residual differences vs a 2017 factory package
(`00 05 00 00 06 01`, tag `A033`) did not prevent import - **do not hand-edit
header bytes**, an unknown digest may cover them.

## 6. Symptoms of a wrong loader

| tool | message | log line |
|---|---|---|
| RKDevTool v3.x | 固件导入失败，固件中Loader摘要检查失败，请检查loader | `Error:Loading loader failed,err=-9` / `create image object failed,ret=-9` |
| AndroidTool v2.84 | 载入固件失败 | `Error:Loading firmware failed,err=-2009` |

The check runs **before any content is read and before the tool writes its log**
in some builds, so it is independent of device state, USB link and package size.
A later `设备类型不匹配` during 下载Boot is a different check: the loader's
declared chip tag does not match the device.
