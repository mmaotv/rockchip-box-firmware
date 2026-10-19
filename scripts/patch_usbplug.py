#!/usr/bin/env python3
"""Neutralise the 32 MiB read guard inside RK3328's usbplug.

From the disassembly (file offsets):

    00A0B0  ldr  w8, [x10]          ; requested end position
    00A0B4  ldr  w9, [x9, #0x9c4]   ; the 32 MiB limit variable
    00A0B8  cmp  w8, w9
    00A0BC  b.hs #0xa104            ; <- take this and you get memset(buf,0xCC,n)
    00A0C0  ... real read ...  bl #0x9650
    00A104  mov  w1,#0xcc ; ldr x0,[buf] ; bl memset

Patching 0xA0BC to NOP (0xD503201F) makes the filler path unreachable, which is
exactly what the xrock project's `&& 0` patch does to U-Boot's
RKUSB_READ_LIMIT_ADDR check.  We never touch flash: the loader only ever runs
from DDR.
"""
import hashlib
import sys

from capstone import CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN, Cs

SRC = r"d:\APPDEV\zhushouAPP\_rk_backup\rkbin\bin\rk33\rk322xh_usbplug_v2.54.bin"
DST = r"d:\APPDEV\zhushouAPP\_rk_backup\rkbin\bin\rk33\rk322xh_usbplug_v2.54_no32Mguard.bin"
PATCH_OFF = 0xA0BC
NOP = bytes.fromhex("1F2003D5")

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
d = bytearray(open(SRC, "rb").read())
print("src %s  %d bytes" % (SRC, len(d)))
print("sha256(src) = %s" % hashlib.sha256(bytes(d)).hexdigest().upper())

orig = bytes(d[PATCH_OFF:PATCH_OFF + 4])
print("\n原始 0x%X 处字节: %s" % (PATCH_OFF, orig.hex(" ").upper()))
for ins in md.disasm(orig, PATCH_OFF):
    print("  -> %s %s" % (ins.mnemonic, ins.op_str))

print("\n补丁前上下文 0x%X..0x%X:" % (PATCH_OFF - 16, PATCH_OFF + 16))
for ins in md.disasm(bytes(d[PATCH_OFF - 16:PATCH_OFF + 16]), PATCH_OFF - 16):
    mark = "   <=== 这里" if ins.address == PATCH_OFF else ""
    print("  %06X  %-8s %s%s" % (ins.address, ins.mnemonic, ins.op_str, mark))

# only patch if it really is a conditional branch to 0xa104
ok = False
for ins in md.disasm(orig, PATCH_OFF):
    if ins.mnemonic.startswith("b.") and ins.op_str == "#0xa104":
        ok = True
if not ok:
    print("\n拒绝打补丁：该位置不是预期的条件分支")
    sys.exit(1)

d[PATCH_OFF:PATCH_OFF + 4] = NOP
print("\n补丁后:")
for ins in md.disasm(bytes(d[PATCH_OFF - 8:PATCH_OFF + 12]), PATCH_OFF - 8):
    mark = "   <=== 已改为 NOP" if ins.address == PATCH_OFF else ""
    print("  %06X  %-8s %s%s" % (ins.address, ins.mnemonic, ins.op_str, mark))

with open(DST, "wb") as f:
    f.write(bytes(d))
print("\n写出 %s" % DST)
print("sha256(new) = %s" % hashlib.sha256(bytes(d)).hexdigest().upper())
print("改动字节数: 4")
