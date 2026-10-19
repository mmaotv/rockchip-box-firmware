# 配套工具与驱动 / Bundled tools & drivers

本目录附带**瑞芯微（Rockchip）官方开发工具与 Rockusb 驱动**的已验证可用副本，
目的是让本技能（skill）及其脚本在没有外网下载的情况下也能直接运行——AI 助手 / 各类
agent 不必自行去网上找工具即可驱动设备、打包固件。

> **许可与来源声明 / License & provenance**
> RKDevTool、AndroidTool、AFPTool、RKImageMaker 以及 Rockusb 驱动均为
> **瑞芯微（Rockchip） proprietary 工具**，版权归 Rockchip 所有。本仓库将其随各机型
> SDK / 固件发布包附带，仅为使用便利而再分发；使用者须自行遵守 Rockchip 的许可条款。
> 官方工具通常随 Rockchip 各平台 SDK 与固件发布包提供，也可从瑞芯微官方资源中心获取。
> 各文件均经 `SHA256SUMS.txt` 记录哈希，使用前请校验完整性。

## 目录内容 / Contents

| 路径 | 用途 | 平台 |
|---|---|---|
| `RKDevTool_v3.37/RKDevTool.exe` | 现代平台烧写工具（GUI，按控件 id 驱动） | RK3566 / RK3568 / Android 11+ |
| `RKDevTool_v3.37/bin/AFPTool.exe` | RKAF 打包（v2.28） | 同上 |
| `RKDevTool_v3.37/bin/RKImageMaker.exe` | RKFW 镜像封装（v2.23） | 同上 |
| `AndroidTool_v2.84/AndroidTool.exe` | 传统平台烧写工具（GUI） | RK3368 / RK330A / Android 5.x |
| `AndroidTool_v2.84/bin/AFPTool.exe` | RKAF 打包（v1.65） | 同上 |
| `AndroidTool_v2.84/bin/RKImageMaker.exe` | RKFW 镜像封装（v1.67） | 同上 |
| `Rockusb_Driver/` | Rockusb 驱动（x64/x86，win7/win8/xp） | 所有平台（连接 MASKROM/Loader 必需） |
| `*/bin/adb.exe` + `AdbWinApi.dll` + `AdbWinUsbApi.dll` | 随工具附带的 ADB（用于 shell / pull） | 所有平台 |
| `*/Language/*.ini`、`config.cfg`、`config.ini`、`revision.txt` | 工具语言包与配置 | — |
| `*/开发工具使用文档_v1.0.pdf`、`RKDevTool_manual_v1.2_*.pdf` | 官方使用手册 | — |

> 打包固件时**工具代际必须匹配**（见 `SKILL.md` 与 `scripts/build_firmware.ps1`）：
> 传统平台用 `AndroidTool_v2.84/bin`，现代平台用 `RKDevTool_v3.37/bin`。
> 切勿把 2024 年的 AFPTool 与 2021 年的 RKImageMaker 混用。

## 给 AI 助手 / 脚本的路径约定 / Path conventions

- 烧写：先确认设备进入 MASKROM / Loader 且 `Get-PnpDevice` 能看到 `VID_2207`，
  然后启动对应工具：
  - 现代平台：`tools/RKDevTool_v3.37/RKDevTool.exe`
  - 传统平台：`tools/AndroidTool_v2.84/AndroidTool.exe`
  `scripts/rk_tool.ps1` 会**自动附加到正在运行的工具窗口**（按控件 id 而非坐标驱动），
  因此只要工具已打开即可，无需硬编码路径。
- 打包：`scripts/build_firmware.ps1` 的 `-ToolBin` 默认指向
  `tools/RKDevTool_v3.37/bin`；传统平台请改为 `tools/AndroidTool_v2.84/bin`。
- 驱动：`Rockusb_Driver/` 内为 `.inf/.sys/.cat`。Windows 上需**先安装驱动**才能识别设备：
  以管理员身份对 `rockusb.inf` 右键「安装」，或运行随包 `DriverAssistant`；
  安装后 `VID_2207` 设备才会出现在设备管理器中。

## 完整性校验 / Integrity check

```
# PowerShell
Get-FileHash -Algorithm SHA256 tools/RKDevTool_v3.37/bin/AFPTool.exe
# 对照 SHA256SUMS.txt 中对应行的哈希
```

所有文件哈希见 `tools/SHA256SUMS.txt`（由 `Get-FileHash -Algorithm SHA256` 生成）。
