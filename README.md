# 瑞芯微（Rockchip）机顶盒固件工具集

> Rockchip Box Firmware Toolkit — a reproducible pipeline to **identify, back up,
> verify, modify and re-package** the firmware of Rockchip (瑞芯微) TV boxes and
> development boards, so a bricked device can always be recovered.

English abstract below. 中文说明为主。

---

## 这是什么 / What it is

一套端到端的工作流，覆盖瑞芯微设备的固件全生命周期：

**识别设备 →（先备份分区表 + mini loader）→ 完整备份 → 校验 → 改 system → 打包固件包 → 验收 → 归档**

它适用于两类瑞芯微平台，差异只在三处：

| | 传统平台（RK3368 / RK330A，Android 5.x） | 现代平台（RK3566 / RK3568，Android 11+） |
|---|---|---|
| 分区表 | `PARM` 块（sector 0，`mtdparts=rk29xxnand:...`） | GPT（`EFI PART`，LBA 1） |
| 系统 | 独立 `system` 分区 | `system/vendor/product` 位于 `super`（动态分区），按需原地编辑 |
| 工具对 | AndroidTool v2.84（AFPTool v1.65 + RKImageMaker 1.67） | RKDevTool v3.3x（AFPTool v2.28 + RKImageMaker 2.23） |

## 核心铁律 / Hard rules

1. **任何备份或修改之前，第一步必须先备份分区表和 mini loader。** 二者一旦丢失，机器将永久无法恢复。详见 `SKILL.md` 的 Step 0 与 `references/pitfalls.md` 第 0 章。
2. **每个步骤都能脱离设备独立校验。** 不要只信某一个工具的"成功"提示，要从字节本身重新推导（大小、跨 dump 比对、GPT CRC32、liblp SHA256）。
3. **loader 必须是合并容器（BOOT/LDR）。** 单个 rkbin 组件（ddr / usbplug / spl）永远无法导入，无论工具版本或参数如何。
4. **先打小包验证 loader，再打全包。** 导入校验早于内容读取，小包几秒就能证明 loader 是否正确。

## 目录结构 / Layout

```
SKILL.md                 技能主文件（完整工作流与铁律）
references/              深度文档
  pitfalls.md            错误码、成因与对策；脚本陷阱（含第 0 章强制备份）
  backup-and-restore.md  分区表/GPT 解析、扇区运算、导出策略、三种恢复路径
  tool-config-format.md  下载镜像配置（CFG\0）字节布局与生成方法
  firmware-package-format.md  RKFW/RKAF 字节布局、loader 容器、提取配方
  case-legacy-rk3368.md  传统平台完整实战样例
  case-modern-rk3328.md  现代平台（GPT + 动态分区）实战样例
scripts/                 驱动工具与校验脚本
  rk_tool.ps1            按控件 id 驱动 RKDevTool/AndroidTool（绝不靠坐标，避免误触破坏性按钮）
  verify_backup.ps1      大小校验 + 分区/整盘逐字节交叉比对 + 产出 sha256.txt
  rk_config.py           读写工具下载配置（CFG\0）
  append_export.ps1      超大分区分批导出并续传
  build_firmware.ps1     AFPTool + RKImageMaker 打包并校验 RKFW 头与 loader 区
  scan_markers.py        字节扫描镜像中的桌面/应用特征
  lpverify.py / merge_two.py / merge_super.py / patch_usbplug.py / checkread.py / redo_partitions.ps1
```

## 快速开始 / Quick start

1. 准备工具：`RKDevTool`（现代）或 `AndroidTool`（传统），以及 **Rockusb 驱动（DriverAssistant）**。
2. 进入设备连接状态（MASKROM / Loader），确认 `Get-PnpDevice` 能看到 `VID_2207`。
3. **先执行 Step 0**：导出前 0x2000 扇区（含分区表 + loader 区），并从中切出 `MiniLoaderAll.bin`；按设备按钮抓取分区表清单。
4. 按 `SKILL.md` 的流程完成备份、校验、修改、打包。
5. 归档必须自包含（镜像 + 工具 + 驱动 + 文档 + 一份工厂参考包 + `sha256.txt`），并复制到另一块物理磁盘。

## 适用场景 / Scope

- 设备 owners / 维修人员对自己的瑞芯微盒子做系统精简、换桌面、去广告。
- 研究者做固件备份、分析与再打包。
- **不适用于**：绕过厂商授权、破解付费内容、或任何违反设备保修/当地法律的行为。

## 免责声明 / Disclaimer

本工具集仅供对自身合法持有的设备进行操作。修改系统可能使保修失效、导致设备无法启动；
操作前请务必完成完整备份（尤其分区表与 mini loader）。作者与贡献者对任何数据丢失或设备损坏不承担责任。

## 许可证 / License

[MIT](LICENSE) — 自由使用、修改与再分发，需保留版权声明。
