#!/usr/bin/env python3
"""Merge the two parity-shifted passes of super and verify with liblp's own CRCs.

Pass A starts at super_start        -> even 64 KiB blocks are 0xCC filler
Pass B starts at super_start - 64KB -> its blocks are shifted by one, so the
filler sits on the other parity.  For each 64 KiB block of super we therefore
take A unless A is filler, in which case we take B's copy (at +64 KiB).

Verification (independent of any host tool):
  * LpMetadataGeometry at +4096 : magic 0x616c4467, CRC32 of the struct
  * LpMetadataHeader  at +8192   : magic 0x414c5030, CRC32 of the header
  * CRC32 of the tables
  * partition / group / block-device names
"""
import os
import re
import struct
import zlib

W = r"d:\APPDEV\zhushouAPP\_rk_backup\work"
A = os.path.join(W, "superA.bin")
B = os.path.join(W, "superB.bin")
OUT = os.path.join(W, "super_merged.img")

SUPER_START = 1970176
COUNT = 0x614000
BLK = 65536
TARGET = COUNT * 512          # 3,263,954,944
B_SHIFT = 131072              # B's file offset for flash x is x + 131072?  no: see below
# A[i]   = flash[super_start + i]
# B[j]   = flash[super_start - 65536 + j]  ->  flash[super_start + x] = B[x + 65536]
B_OFF = 65536

szA, szB = os.path.getsize(A), os.path.getsize(B)
print("A=%d 字节 (%d 块)  B=%d 字节 (%d 块)  目标=%d 字节 (%d 块)" %
      (szA, szA // BLK, szB, szB // BLK, TARGET, TARGET // BLK))
if szA < TARGET or szB < TARGET + B_OFF:
    print("!! 输入文件偏小，可能读取不完整，先检查")
    raise SystemExit(1)

fa = open(A, "rb")
fb = open(B, "rb")
fo = open(OUT, "wb")
fromA = fromB = 0
both_filler = 0
fill_positions = []
for i in range(TARGET // BLK):
    fa.seek(i * BLK)
    a = fa.read(BLK)
    if a.count(0xCC) == BLK:
        fb.seek(i * BLK + B_OFF)
        b = fb.read(BLK)
        if b.count(0xCC) == BLK:
            both_filler += 1
            fill_positions.append(i)
        else:
            fromB += 1
        fo.write(b)
    else:
        fromA += 1
        fo.write(a)
fo.close()
fa.close()
fb.close()
print("合并完成：A 提供 %d 块，B 提供 %d 块，两遍都是填充的块 %d" %
      (fromA, fromB, both_filler))
print("输出 %s  %d 字节" % (OUT, os.path.getsize(OUT)))

d = open(OUT, "rb").read()

print()
print("=== liblp 校验 ===")
geo = d[4096:4096 + 128]
magic, struct_size, checksum, max_size, slots, blk = struct.unpack_from("<IIIIII", geo, 0)
print("  geometry: magic=0x%08X (期望 0x616C4467) struct_size=%d crc=0x%08X" % (magic, struct_size, checksum))
print("            metadata_max_size=%d  slot_count=%d  logical_block_size=%d" % (max_size, slots, blk))
g = bytearray(geo[:struct_size])
g[8:12] = b"\x00" * 4
calc = zlib.crc32(bytes(g)) & 0xFFFFFFFF
print("  geometry CRC: 存储=0x%08X 计算=0x%08X %s" % (checksum, calc, "OK √" if calc == checksum else "不符 ×"))

slot0 = 4096 + struct_size * 2
h = d[slot0:slot0 + 256]
hm, hmaj, hmin, hsz, hcrc, tsz, tcrc = struct.unpack_from("<IHHIIII", h, 0)
print("  header(slot0 @%d): magic=0x%08X (期望 0x414C5030) major=%d minor=%d header_size=%d" %
      (slot0, hm, hmaj, hmin, hsz))
hh = bytearray(d[slot0:slot0 + hsz])
hh[12:16] = b"\x00" * 4
calc2 = zlib.crc32(bytes(hh)) & 0xFFFFFFFF
print("  header CRC: 存储=0x%08X 计算=0x%08X %s" % (hcrc, calc2, "OK √" if calc2 == hcrc else "不符 ×"))

toff, tlen = struct.unpack_from("<II", h, 24) if False else (None, None)
# 表头里的 descriptors 是相对 metadata 起点(slot0)的偏移
poff, pnum, psz = struct.unpack_from("<III", h, 24)
eoff, enum, esz = struct.unpack_from("<III", h, 36)
goff, gnum, gsz = struct.unpack_from("<III", h, 48)
boff, bnum, bsz = struct.unpack_from("<III", h, 60)
print("  tables: partitions(off=%d num=%d sz=%d) extents(%d/%d/%d) groups(%d/%d/%d) block_devices(%d/%d/%d)" %
      (poff, pnum, psz, eoff, enum, esz, goff, gnum, gsz, boff, bnum, bsz))
if tsz:
    tb = d[slot0 + hsz: slot0 + hsz + tsz]
    calc3 = zlib.crc32(tb) & 0xFFFFFFFF
    print("  tables CRC: 存储=0x%08X 计算=0x%08X %s" % (tcrc, calc3, "OK √" if calc3 == tcrc else "不符 ×"))

print("  分区表:")
for i in range(pnum):
    o = slot0 + poff + i * psz
    nm = d[o:o + 36].split(b"\x00")[0].decode("ascii", "replace")
    attrs, fx, nx, gi = struct.unpack_from("<IIII", d, o + 36)
    print("     [%d] %-12s extents=%d..%d group=%d" % (i, nm, fx, fx + nx - 1, gi))
print("  group 名:")
for i in range(gnum):
    o = slot0 + goff + i * gsz
    print("     [%d] %s" % (i, d[o:o + 36].split(b"\x00")[0].decode("ascii", "replace")))
print("  block device 名:")
for i in range(bnum):
    o = slot0 + boff + i * bsz
    print("     [%d] %s" % (i, d[o:o + 36].split(b"\x00")[0].decode("ascii", "replace")))

print()
print("=== 内容统计 ===")
import collections
c = collections.Counter(d)
print("  %d 字节, %d 种字节值" % (len(d), len(c)))
print("  top: " + ", ".join("0x%02X:%.1f%%" % (k, 100.0 * v / len(d)) for k, v in c.most_common(5)))
print("  非 0xCC 字节 = %d (%.1f%%)" % (len(d) - c[0xCC], 100.0 * (len(d) - c[0xCC]) / len(d)))
if fill_positions:
    print("  两遍都填充的块号（若很多说明规律不同）: %s" % fill_positions[:20])
