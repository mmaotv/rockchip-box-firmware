#!/usr/bin/env python3
"""rk_config.py -- read / write the RKDevTool image-download config (magic "CFG\\0").

WHY THIS EXISTS
  A partition backup without this file is only half a restore kit: the "download
  image" page needs one row per partition (start sector + image file), and typing
  15 rows by hand is where mistakes happen. The tool keeps that list in a binary
  config file that it also loads on startup, so generating it is the difference
  between "one click and go" and "type 15 addresses".

  The layout below was confirmed by decoding two files RKDevTool had written
  itself (an 11-row legacy eMMC config with addresses and ticks, and an 18-row one
  with a loader path): every address and every size decoded back to the values
  the partition table says they must be.

FILE LAYOUT
  header : 29 bytes
      0..3    "CFG\\0"
      4..5    u16 29              (header size)
      6..7    u16 year
      8..9    u16 month
      10..11  u16 1               (constant in every sample)
      12..13  u16 day
      14..15  u16 hour
      16..17  u16 minute
      18..19  u16 second
      20..21  u16 millisecond
      22      u8  record count
      23      u8  29              (header size, again)
      24..26  00 00 00
      27..28  62 02               (constant; replicates what the tool writes)
  record : 610 bytes each, repeated `count` times
      0..1    u16 610             (0x0262, record size)
      2..609  608-byte payload:
          +0    name      UTF-16LE, 32 chars  = 64 bytes
          +64   16 bytes, zero in every sample
          +80   file path UTF-16LE, 256 chars = 512 bytes
          +592  u32 size in 128 KiB units (= ceil(sector_count / 256))
          +596  u32 zero
          +600  u32 start sector (LE)
          +604  u32 flags: bit0 = row ticked (a ticked row is what gets written)

MODES
  make : python -X utf8 rk_config.py make <spec.csv> <out.cfg>
         spec lines:  name,start_sector,count_sectors[,image_path]
         start/count accept 0x.. or decimal. '#' starts a comment, blank lines
         are ignored. A row with no image path is written UNTICKED (the tool
         skips unticked rows), which is the safe way to document a partition
         that has no backup image.
  dump : python -X utf8 rk_config.py dump <file.cfg>
  selftest : python -X utf8 rk_config.py selftest <known_good.cfg>
         Re-reads a file RKDevTool itself wrote, rebuilds every byte from the
         decoded fields, and diffs the result. Running this on one or two files
         the tool produced is what proves the writer above - and any config
         generated from it - is byte-correct.
"""
import datetime
import os
import struct
import sys

HEADER_SIZE = 29
RECORD_SIZE = 610
PAYLOAD_SIZE = 608
NAME_CHARS = 32
PATH_CHARS = 256

# header bytes 10..11: which storage the row list was built for. Decoded by
# comparing 60+ real configs on this machine - the tool's own storage list
# (control id 1060, 0-based here) reads
#   0 FLASH  1 EMMC  2 SD  3 SD1  4 SPINOR  5 SPINAND  6 RAM  7 USB ...
# Every legacy eMMC file the tool wrote carries 1, the SPI-NOR
# board configs carry 4. A wrong value here is what makes an imported list look
# empty, so it is an explicit parameter.
STORAGE_TYPES = {0: "FLASH", 1: "EMMC", 2: "SD", 3: "SD1", 4: "SPINOR",
                 5: "SPINAND", 6: "RAM", 7: "USB", 8: "SATA", 9: "PCIE",
                 10: "UFS", 11: "RVD"}


def build_payload(name, path, count_sectors, start_sector, ticked):
    if len(name) > NAME_CHARS:
        raise ValueError("name too long for the 32-char field: %r" % name)
    if len(path) > PATH_CHARS:
        raise ValueError("path too long for the 256-char field (%d): %s" % (len(path), path))
    pay = bytearray(PAYLOAD_SIZE)
    nm = name.encode("utf-16le")
    pay[0:len(nm)] = nm
    pth = path.encode("utf-16le")
    pay[80:80 + len(pth)] = pth
    struct.pack_into("<I", pay, 592, -(-count_sectors // 256))   # size in 128 KiB units
    struct.pack_into("<I", pay, 600, start_sector)
    struct.pack_into("<I", pay, 604, 1 if ticked else 0)
    return bytes(pay)


def build_header(count, when=None, storage=1):
    when = when or datetime.datetime.now()
    h = bytearray()
    h += b"CFG\x00"
    h += struct.pack("<H", HEADER_SIZE)
    h += struct.pack("<HHH", when.year, when.month, storage)
    h += struct.pack("<HHHHH", when.day, when.hour, when.minute,
                     when.second, when.microsecond // 1000)
    h += bytes([count & 0xFF, HEADER_SIZE])
    h += b"\x00\x00\x00"
    h += b"\x62\x02"
    assert len(h) == HEADER_SIZE, len(h)
    return bytes(h)


def parse_spec(path):
    rows = []
    with open(path, "r", encoding="utf-8-sig") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                raise ValueError("line %d: need name,start,count[,path]" % lineno)
            name, start, count = parts[0], int(parts[1], 0), int(parts[2], 0)
            image = parts[3] if len(parts) > 3 else ""
            rows.append((name, start, count, image))
    if not rows:
        raise ValueError("spec has no rows")
    return rows


def cmd_make(spec, out, storage=1):
    rows = parse_spec(spec)
    if len(rows) > 255:
        raise ValueError("more than 255 rows is not representable")
    blob = bytearray(build_header(len(rows), storage=storage))
    for name, start, count, image in rows:
        blob += struct.pack("<H", RECORD_SIZE)
        blob += build_payload(name, image, count, start, bool(image))
    tmp = out + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(blob)
    os.replace(tmp, out)
    now = datetime.datetime.now()
    print("wrote %s  (%d bytes, %d rows)" % (out, len(blob), len(rows)))
    print("header: size=29 year=%d month=%d day=%d %02d:%02d:%02d  count=%d  storage=%d (%s)"
          % (now.year, now.month, now.day, now.hour, now.minute, now.second,
             len(rows), storage, STORAGE_TYPES.get(storage, "?")))
    ticked = sum(1 for r in rows if r[3])
    print("rows with an image (ticked, will be written): %d ; rows without: %d"
          % (ticked, len(rows) - ticked))
    expect = HEADER_SIZE + RECORD_SIZE * len(rows)
    print("size check: %d == %d %s" % (len(blob), expect, "OK" if len(blob) == expect else "MISMATCH"))
    for rec in (0, len(rows) - 1):
        print("  row %d: %s @0x%X" % (rec, rows[rec][0], rows[rec][1]))


def cmd_dump(path):
    d = open(path, "rb").read()
    if d[:4] != b"CFG\x00":
        raise SystemExit("not a CFG file (magic=%r)" % d[:4])
    u16 = lambda o: int.from_bytes(d[o:o + 2], "little")
    print("==== %s  %d bytes" % (os.path.basename(path), len(d)))
    print("year=%d month=%d day=%d %02d:%02d:%02d.%03d  count=%d  header=%d"
          % (u16(6), u16(8), u16(12), u16(14), u16(16), u16(18), u16(20), d[22], d[23]))
    n = (len(d) - HEADER_SIZE) // RECORD_SIZE
    if d[22] != n:
        print("WARNING: header count %d but file holds %d records" % (d[22], n))
    print("  %-3s %-16s %-12s %-11s %-5s %s" % ("#", "name", "start", "size/128KiB", "tick", "image"))
    for i in range(n):
        s = HEADER_SIZE + i * RECORD_SIZE
        mark = int.from_bytes(d[s:s + 2], "little")
        pay = d[s + 2:s + 2 + PAYLOAD_SIZE]
        name = pay[0:64].decode("utf-16le", "replace").split("\x00")[0]
        image = pay[80:592].decode("utf-16le", "replace").split("\x00")[0]
        size = int.from_bytes(pay[592:596], "little")
        addr = int.from_bytes(pay[600:604], "little")
        tick = int.from_bytes(pay[604:608], "little")
        flag = "" if mark == RECORD_SIZE else "  MARK=%d!" % mark
        print("  %-3d %-16s 0x%08X  %-11d %-5d %s%s" % (i, name, addr, size, tick, image, flag))


def read_records(path):
    d = open(path, "rb").read()
    if d[:4] != b"CFG\x00":
        raise SystemExit("not a CFG file (magic=%r)" % d[:4])
    n = (len(d) - HEADER_SIZE) // RECORD_SIZE
    rows = []
    for i in range(n):
        s = HEADER_SIZE + i * RECORD_SIZE
        pay = d[s + 2:s + 2 + PAYLOAD_SIZE]
        rows.append((
            pay[0:64].decode("utf-16le").split("\x00")[0],
            int.from_bytes(pay[600:604], "little"),
            int.from_bytes(pay[592:596], "little") * 256,
            pay[80:592].decode("utf-16le").split("\x00")[0],
            int.from_bytes(pay[604:608], "little"),
        ))
    return d, rows


def cmd_selftest(path):
    d, rows = read_records(path)
    u16 = lambda o: int.from_bytes(d[o:o + 2], "little")
    when = datetime.datetime(u16(6), u16(8), u16(12), u16(14), u16(16), u16(18), u16(20) * 1000)
    blob = bytearray(build_header(d[22], when, storage=u16(10)))
    for name, start, count, image, tick in rows:
        blob += struct.pack("<H", RECORD_SIZE)
        blob += build_payload(name, image, count, start, tick)
    print("==== selftest %s" % os.path.basename(path))
    print("     rows=%d  original=%d bytes  rebuilt=%d bytes" % (len(rows), len(d), len(blob)))
    if len(d) != len(blob):
        print("     SIZE MISMATCH -> writer layout is wrong")
        return 1
    diff = [i for i in range(len(d)) if d[i] != blob[i]]
    if not diff:
        print("     RESULT: byte-identical - the writer reproduces the tool's own file exactly")
        return 0
    print("     RESULT: %d differing byte(s), first at %d (rec %d rel %d)"
          % (len(diff), diff[0], (diff[0] - HEADER_SIZE) // RECORD_SIZE,
             (diff[0] - HEADER_SIZE) % RECORD_SIZE))
    for i in diff[:8]:
        print("        offset %d: original=0x%02X rebuilt=0x%02X" % (i, d[i], blob[i]))
    return 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(2)
    mode = sys.argv[1].lower()
    if mode == "make" and len(sys.argv) >= 4:
        cmd_make(sys.argv[2], sys.argv[3],
                 int(sys.argv[4], 0) if len(sys.argv) > 4 else 1)
    elif mode == "dump":
        cmd_dump(sys.argv[2])
    elif mode == "selftest":
        raise SystemExit(cmd_selftest(sys.argv[2]))
    else:
        print(__doc__)
        raise SystemExit(2)
