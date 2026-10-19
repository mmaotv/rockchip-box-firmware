#!/usr/bin/env python3
"""scan_markers.py -- identify what is inside a Rockchip system image, without
mounting it.

WHY
  Windows cannot mount ext4, and Android 10+ boxes hide system/vendor/product
  inside a single super.img (dynamic partitions) that is not ext4 at all. But the
  question that actually matters during this workflow is narrower:

      which image carries which launcher / which pre-installed app?

  That can be answered by a byte search. APK file names live as plain ASCII in
  ext4 directory data, and super.img embeds the same ext4 images, so the strings
  are found either way. Chinese app names are usually stored as UTF-8 in
  resources, so they are searched as UTF-8 byte sequences.

  Typical use:
    * compare an original system dump with a modified one
    * confirm which system a firmware package actually carries
      (the full package contains it; a lean test package does not)
    * after repacking a super.img, verify your changes really landed

USAGE
    python scan_markers.py <image> [<image> ...]
    python scan_markers.py --pattern Emotn --pattern "当贝:utf8" <image> ...

  Patterns are matched case-sensitively as raw bytes. Append ':utf8' to encode
  the pattern as UTF-8 (use for Chinese names); default is ASCII.
  Exit code is 0 always -- this is a report, not a gate.
"""

import argparse
import os
import sys

DEFAULT_PATTERNS = [
    # launchers / app stores commonly pre-installed on Chinese TV boxes
    "Emotn",          # EmotnUI launcher
    "emotn",
    "dangbei",        # 当贝市场
    "com.dangbei",
    "DBMarket",
    "Launcher",       # generic; a high baseline count in every image is normal
    "当贝:utf8",
    "应用管家:utf8",
]


def build_patterns(extra):
    items = []
    for raw in (extra if extra else DEFAULT_PATTERNS):
        if raw.endswith(":utf8"):
            name, data = raw[:-5], raw[:-5].encode("utf-8")
        else:
            name, data = raw, raw.encode("ascii", "ignore")
        if data:
            items.append((name, data))
    return items


def scan(path, patterns):
    try:
        size = os.path.getsize(path)
    except OSError as exc:
        print("MISSING %s (%s)" % (path, exc))
        return None
    print("==== %s  %d bytes" % (os.path.basename(path), size))
    with open(path, "rb") as fh:
        data = fh.read()
    out = {}
    for name, pat in patterns:
        count = data.count(pat)
        first = data.find(pat)
        out[name] = (count, first)
        if count:
            print("     %-18s count=%-6d first@0x%X" % (name, count, first))
        else:
            print("     %-18s count=0" % name)
    del data
    return out


def main():
    ap = argparse.ArgumentParser(description="byte-scan a system image for launcher/app markers")
    ap.add_argument("images", nargs="+", help="image files to scan")
    ap.add_argument("-p", "--pattern", action="append", default=[],
                    help="extra pattern; append :utf8 for Chinese, repeatable")
    args = ap.parse_args()

    patterns = build_patterns(args.pattern)
    results = {}
    for img in args.images:
        results[img] = scan(img, patterns)

    # side-by-side summary, easy to eyeball when comparing images
    names = [n for n, _ in patterns if any(r and r.get(n, (0, -1))[0] for r in results.values())]
    if len(results) > 1 and names:
        print("\n==== summary (counts, non-zero patterns only) ====")
        head = "%-28s" % "pattern"
        for img in results:
            head += "%18s" % os.path.basename(img)[:17]
        print(head)
        for n in names:
            row = "%-28s" % n
            for img in results:
                r = results[img]
                row += "%18s" % (r.get(n, (0, 0))[0] if r else 0)
            print(row)

    print("\nnote: 'Launcher' matches framework strings and is high in every image;")
    print("      judge by the distinctive markers (Emotn / dangbei / app names),")
    print("      and always keep a stock image as the baseline for comparison.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
