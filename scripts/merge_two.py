#!/usr/bin/env python3
"""Merge two parity-shifted passes of one partition image.

  merge_two.py <A.bin> <B.bin> <out.img> <sector_count>

A is the export that starts at the partition's first LBA; B is the export that
starts 64 KiB (128 sectors) earlier.  In every export the even-numbered 64 KiB
blocks come back as 0xCC filler, so for each block of the target we take A's copy
unless A is filler, in which case B's copy at +65536 is the real one.
"""
import collections
import hashlib
import os
import sys

if len(sys.argv) < 5:
    print(__doc__)
    raise SystemExit(2)
A, B, OUT, COUNT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 0)
BLK = 65536
TARGET = COUNT * 512
B_OFF = 65536

szA, szB = os.path.getsize(A), os.path.getsize(B)
print("A=%d  B=%d  目标=%d (%d 块, %d 扇区)" % (szA, szB, TARGET, TARGET // BLK, COUNT))
if szA < TARGET or szB < TARGET + B_OFF:
    print("!! 输入偏小：A 需要 >=%d，B 需要 >=%d" % (TARGET, TARGET + B_OFF))
    raise SystemExit(1)

fa, fb, fo = open(A, "rb"), open(B, "rb"), open(OUT, "wb")
fromA = fromB = 0
bothf = []
for i in range(TARGET // BLK):
    fa.seek(i * BLK)
    a = fa.read(BLK)
    if a.count(0xCC) == BLK:
        fb.seek(i * BLK + B_OFF)
        b = fb.read(BLK)
        if b.count(0xCC) == BLK:
            bothf.append(i)
        fromB += 1
        fo.write(b)
    else:
        fromA += 1
        fo.write(a)
fo.close()
fa.close()
fb.close()

d = open(OUT, "rb").read()
print("合并：A 提供 %d 块，B 提供 %d 块，两遍都填充的块 %d %s" %
      (fromA, fromB, len(bothf), ("-> " + str(bothf[:12])) if bothf else "(完美互补)"))
c = collections.Counter(d)
print("输出 %s  %d 字节" % (OUT, len(d)))
print("  字节种类=%d  top=%s  非0xCC=%d (%.2f%%)" %
      (len(c), ", ".join("0x%02X:%.1f%%" % (k, 100.0 * v / len(d)) for k, v in c.most_common(4)),
       len(d) - c[0xCC], 100.0 * (len(d) - c[0xCC]) / len(d)))
print("  前 32 字节: %s" % d[:32].hex(" "))
print("  前 32 ASCII: %s" % "".join(chr(b) if 32 <= b < 127 else "." for b in d[:32]))
print("  SHA256 = %s" % hashlib.sha256(d).hexdigest().upper())
for magic, what in [(b"ANDROID!", "Android boot/recovery 镜像头"),
                    (b"BOOT", "Rockchip IDBlock"),
                    (b"LOGO", "Rockchip logo"),
                    (b"RKAF", "Rockchip update 包")]:
    idx = d.find(magic)
    if idx == 0:
        print("  魔数 %s 在偏移 0 -> %s √" % (magic.decode(), what))
    elif idx > 0:
        print("  魔数 %s 出现在偏移 0x%X -> %s" % (magic.decode(), idx, what))
