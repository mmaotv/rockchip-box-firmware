#!/usr/bin/env python3
"""Verify a dumped super image with liblp's own SHA256 checksums.

Layout (liblp/metadata_format.h):
  0        .. 4096      reserved
  4096     .. 8192      LpMetadataGeometry      (magic 0x616C4467)
  8192     .. 12288     backup geometry
  12288    ..          slot 0 metadata          (metadata_max_size bytes)
  +max     ..          slot 1 metadata (backup)

LpMetadataGeometry: magic u32, struct_size u32, checksum sha256[32],
                    metadata_max_size u32, metadata_slot_count u32,
                    logical_block_size u32            (sizeof = 52)
LpMetadataHeader:   magic u32 = 0x414C5030, major u16, minor u16, header_size u32,
                    header_checksum sha256[32], tables_size u32,
                    tables_checksum sha256[32], then 4 table descriptors
                    (u32 offset, u32 num_entries, u32 entry_size)  (sizeof = 128)
"""
import hashlib
import os
import struct
import sys

P = sys.argv[1] if len(sys.argv) > 1 else \
    r"d:\APPDEV\zhushouAPP\_rk_backup\work\super_merged.img"
d = open(P, "rb").read()
print("文件 %s  %d 字节\n" % (P, len(d)))

GEO = 4096
magic, struct_size = struct.unpack_from("<II", d, GEO)
geo = bytearray(d[GEO:GEO + struct_size])
stored = bytes(geo[8:40])
geo[8:40] = b"\x00" * 32
calc = hashlib.sha256(bytes(geo)).digest()
max_size, slots, lblk = struct.unpack_from("<III", d, GEO + 40)
print("=== LpMetadataGeometry @4096 ===")
print("  magic            = 0x%08X  %s" % (magic, "OK √" if magic == 0x616C4467 else "×"))
print("  struct_size      = %d" % struct_size)
print("  metadata_max_size= %d (%d KB)" % (max_size, max_size // 1024))
print("  slot_count       = %d" % slots)
print("  logical_block    = %d" % lblk)
print("  checksum(SHA256) 存储=%s" % stored.hex())
print("                   计算=%s  %s" % (calc.hex(), "OK √√" if calc == stored else "不符 ×"))
print()

slot0 = GEO + 4096 * 2
print("=== LpMetadataHeader slot0 @%d ===" % slot0)
hmagic, hmaj, hmin, hsz = struct.unpack_from("<IHHI", d, slot0)
print("  magic       = 0x%08X  %s" % (hmagic, "OK √" if hmagic == 0x414C5030 else "×"))
print("  version     = %d.%d   header_size=%d" % (hmaj, hmin, hsz))
hdr = bytearray(d[slot0:slot0 + hsz])
hstored = bytes(hdr[12:44])
hdr[12:44] = b"\x00" * 32
hcalc = hashlib.sha256(bytes(hdr)).digest()
print("  header_checksum 存储=%s" % hstored.hex())
print("                  计算=%s  %s" % (hcalc.hex(), "OK √√" if hcalc == hstored else "不符 ×"))
tsize = struct.unpack_from("<I", d, slot0 + 44)[0]
tstored = bytes(d[slot0 + 48:slot0 + 80])
tbl = d[slot0 + hsz: slot0 + hsz + tsize]
tcalc = hashlib.sha256(tbl).digest()
print("  tables_size      = %d" % tsize)
print("  tables_checksum 存储=%s" % tstored.hex())
print("                  计算=%s  %s" % (tcalc.hex(), "OK √√" if tcalc == tstored else "不符 ×"))

descs = {}
for i, nm in enumerate(["partitions", "extents", "groups", "block_devices"]):
    off, num, esz = struct.unpack_from("<III", d, slot0 + 80 + i * 12)
    descs[nm] = (off, num, esz)
    print("  %-14s off=%d num=%d entry_size=%d" % (nm, off, num, esz))
print()

off, num, esz = descs["partitions"]
print("=== super 里的逻辑分区（来自元数据） ===")
for i in range(num):
    o = slot0 + hsz + off + i * esz
    nm = d[o:o + 36].split(b"\x00")[0].decode("ascii", "replace")
    attrs, fx, nx, gi = struct.unpack_from("<IIII", d, o + 36)
    print("   [%d] %-12s attributes=0x%X extents=%d..%d group=%d" % (i, nm, attrs, fx, fx + nx - 1, gi))

off, num, esz = descs["extents"]
print("\n=== extents（逻辑映射，共 %d 条） ===" % num)
tot = 0
for i in range(min(num, 40)):
    o = slot0 + hsz + off + i * esz
    sectors, ttype, tdata, tsrc = struct.unpack_from("<QIQI", d, o)
    tot += sectors
    print("   [%2d] sectors=%-8d (%.1f MB) type=0x%X target=%d source=%d" %
          (i, sectors, sectors * 512 / 1048576.0, ttype, tdata, tsrc))
if num > 40:
    print("   ... 其余 %d 条省略" % (num - 40))

off, num, esz = descs["groups"]
print("\n=== groups ===")
for i in range(num):
    o = slot0 + hsz + off + i * esz
    nm = d[o:o + 36].split(b"\x00")[0].decode("ascii", "replace")
    mx = struct.unpack_from("<Q", d, o + 36)[0]
    print("   [%d] %-24s maximum_size=%d" % (i, nm, mx))

off, num, esz = descs["block_devices"]
print("\n=== block devices ===")
for i in range(num):
    o = slot0 + hsz + off + i * esz
    fls, al, alo, size = struct.unpack_from("<QIIQ", d, o)
    nm = d[o + 24:o + 24 + 36].split(b"\x00")[0].decode("ascii", "replace")
    print("   [%d] %-10s first_logical_sector=%d size=%d (%.2f GB) align=%d" %
          (i, nm, fls, size, size * 512 / 1073741824.0, al))
