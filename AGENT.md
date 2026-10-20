# AGENT.md — How an AI assistant should use this skill

This repository is a **skill / instruction set** for operating Rockchip (瑞芯微) TV boxes
and dev boards: identify the device, back it up completely, restore it, debloat / swap the
launcher / remove vendor services, and re-package a flashable `update.img`. It is written
to be **read and executed by an AI assistant / agent** (coding assistant, autonomous
agent, etc.), not just by a human. A human can also follow it directly.

## Entry points (read in this order)

1. **`SKILL.md`** — the authoritative workflow. Follow its Steps 0 → 7 in order. Do not
   skip Step 0.
2. **`references/pitfalls.md`** — read this **before any destructive or write action**,
   especially chapter 0 (always back up the partition table + mini loader first — losing
   them bricks the device permanently) and the error-code lookup tables.
3. **`references/`** — deep docs: `backup-and-restore.md`, `firmware-package-format.md`,
   `tool-config-format.md`, and three worked examples (`case-legacy-rk3368.md`,
   `case-modern-rk3328.md`, `case-real-rk3566-we40.md`).
4. **`scripts/`** — your tools (PowerShell / Python, ASCII-only on purpose). Drive the
   Rockchip GUIs with `scripts/rk_tool.ps1` (by control id, never by screen coordinates).

## Bundled tools — no download needed

`tools/` ships the Rockchip toolchain so the skill runs offline:

- `tools/RKDevTool_v3.37/` — modern boxes (RK3566 / RK3568, Android 11+)
- `tools/AndroidTool_v2.84/` — legacy boxes (RK3368 / RK330A, Android 5.x)
- `tools/Rockusb_Driver/` — the Rockusb USB driver; **install it first** or Windows will
  not see `VID_2207` in MASKROM/Loader mode.

All binary hashes are in `tools/SHA256SUMS.txt` — verify before trusting.

## Hard rules (never skip)

1. **Back up the partition table + mini loader before anything else** (Step 0).
2. **Verify every step byte-for-byte** — never trust a tool's "success" popup alone;
   re-derive sizes / CRC32 / SHA256 from the bytes.
3. The firmware **loader must be a combined container** (BOOT/LDR), never a single rkbin
   component. Single components fail import with `Loading loader failed err=-9` /
   `载入固件失败 err=-2009`.
4. **Build a small package first** to validate the loader, then the full one.

## How to behave

- Keep the human informed of each step and its verification result.
- On any error string, look it up in `references/pitfalls.md` **before guessing**.
- Match the tool generation to the platform: legacy → `tools/AndroidTool_v2.84/bin`,
  modern → `tools/RKDevTool_v3.37/bin` (this is `build_firmware.ps1`'s default).
- The final archive must be self-contained: images + tools + driver + docs + a factory
  reference package + `sha256.txt`, copied to a **second physical disk**.

## Platform quick-map

| platform | SoC | table | tool | loader container |
|---|---|---|---|---|
| legacy | RK3368 / RK330A (Android 5.x) | `PARM` block (sector 0) | AndroidTool v2.84 | `BOOT` 219,470 B |
| modern | RK3566 / RK3568 (Android 11+) | GPT (`EFI PART`) | RKDevTool v3.37 | combined `~480 KiB` via `boot_merger` |
