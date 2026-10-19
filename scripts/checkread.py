#!/usr/bin/env python3
"""Verdict on one exported image: real content, or the 0xCC read-limit filler?"""
import collections
import math
import sys

path = sys.argv[1]
d = open(path, "rb").read()
n = len(d)
c = collections.Counter(d)
cc = c.get(0xCC, 0)
ent = -sum((v / n) * math.log2(v / n) for v in c.values())

hexs = " ".join("%02X" % b for b in d[:32])
asc = "".join(chr(b) if 32 <= b < 127 else "." for b in d[:32])

print("file      : %s" % path)
print("size      : %d bytes" % n)
print("distinct  : %d byte values" % len(c))
print("entropy   : %.3f" % ent)
print("0xCC count: %d (%.2f%%)" % (cc, 100.0 * cc / n))
print("first 32  : %s" % hexs)
print("            %s" % asc)
if cc == n:
    print("VERDICT   : ALL 0xCC  -> still the 32 MiB read-limit filler (FAIL)")
elif cc > n * 0.9 and len(c) <= 3:
    print("VERDICT   : mostly filler (%.1f%% 0xCC, %d distinct) -> FAIL" % (100.0 * cc / n, len(c)))
else:
    print("VERDICT   : REAL DATA -> the read limit is gone (PASS)")
