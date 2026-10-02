<p align="center"><img src="assets/open-sensei-icon.png" width="144" alt="Open Sensei 图标"></p>
<h1 align="center">Open Sensei</h1>
<p align="center">轻量、本地运行的 Mac 系统监测与管理工具。</p>
<p align="center"><a href="README.md">English</a> · <a href="https://github.com/asdfghklddd/open-sensei/releases/latest">下载 DMG</a> · <a href="LICENSE">MIT 许可证</a></p>

Open Sensei 使用原生 **SwiftUI + AppKit**，从菜单栏查看 CPU、内存、电池、温度、风扇、网络和存储，也可打开管理窗口、固定悬浮面板或贴边折叠。

**macOS 14+ · 发布版支持 Apple Silicon · 无订阅 · 无遥测 · 无第三方运行时**

当前 App 界面以中文为主，仓库提供中英双语说明；尚未提供完整英文界面。本项目独立开发，与 Cindori Sensei、coconutBattery 无关联。

## 安装

1. 从 [Releases](https://github.com/asdfghklddd/open-sensei/releases/latest) 下载 `Open-Sensei-1.2.2-arm64.dmg` 和 `SHA256SUMS`。
2. 打开 DMG，将 **Open Sensei.app** 拖到 **Applications**。
3. 推出磁盘映像，从“应用程序”启动。点击菜单栏图标展开，**⌘0** 打开管理窗口。

当前发布包使用 **ad-hoc 签名，尚未通过 Developer ID 公证**。macOS 可能要求你在“系统设置 → 隐私与安全性”中允许打开，请先核对下载来源和校验值。运行 App 不需要 Python、Node、终端或开发工具。详见[安装说明](docs/INSTALL.txt)。

```sh
# 在 DMG 与 SHA256SUMS 所在目录执行。
shasum -a 256 -c SHA256SUMS
```

## 功能

| 模块 | 已实现 |
| --- | --- |
| 系统监测 | CPU、可获取的 GPU 使用率、内存压力与构成、交换空间、可用存储和网速 |
| 菜单栏与面板 | 自选菜单栏指标、模块排序、固定悬浮面板、贴边折叠 |
| 电池 | 电量、循环、剩余 / 满充 / 设计容量、温度、电压、有符号电流和净功率 |
| 供电 | 区分适配器供电能力、实时输入以及电池充入 / 放出功率 |
| 深度电池报告 | 系统健康、控制器版本、寿命温度 / 电压统计、峰值电流、工作时间和电芯组 Qmax |
| 散热 | 温度传感器、风扇转速、临时固定档位与温控曲线 |
| 活动与诊断 | 分接口网速、磁盘活动、按需进程采样和状态检查 |
| 存储管理 | 有预算的目录扫描、所选文件移到废纸篓、应用卸载及关联文件、SMART / TRIM、卷报告和单次测速 |
| 报告与提醒 | 状态预览 / 复制、电池打印报告，以及可选电量、剩余时间、内存压力和空间提醒 |

### 紧凑控制面板

菜单栏面板改为紧凑指标行：CPU 与网速旁嵌入迷你趋势图；内存同时显示 App、联动、压缩及交换用量；存储、GPU 配合小型容量与负载条；电池显示功率、温度、电压和循环次数。点击各行可直接打开对应管理页，顶部状态栏显示热压力、采样频率和最近更新时间。

完整默认面板为 400 × 406 点，比 1.2.1 的 400 × 569 点再缩短约 29%。通过缩小内边距和横向排列相关数据，容纳更多读数及迷你趋势。复用原有有界内存历史与采样周期，不增加硬件轮询或动画定时器。

<p><img src="assets/dashboard-light.png" width="320" alt="浅色紧凑面板"> <img src="assets/dashboard-dark.png" width="320" alt="深色紧凑面板"></p>

*以上为使用示例读数生成的排版预览，并非实时硬件报告。*

### 为不同数据选择不同图表

电量和存储用环图，内存用构成图，容量用同尺度条图，电芯电压用局部放大的点图，寿命温度用范围图。CPU、网络和温度保留时间趋势。容量摘要开启后显示每日柱图。

切换动效尊重“减少动态效果”、低电量模式与较高热压力；图表没有持续动画定时器。

### 电池数据口径

- **系统最大容量**与**标称满充 ÷ 设计容量**分别展示，不能混成一个健康评分。
- 寿命统计来自控制器已有记录，无需先长期运行本 App 收集历史。
- 解析器兼容 macOS 27 的 Pack / Bank 子节点与旧版根字段；具体可用性取决于硬件和固件。
- Qmax 是学习化学容量，串联电芯组 mAh 不相加；电压差不作为单体健康或安全评分。
- 制造月份仅解码可验证字段，并标明推算；不从随机设备序列号推测日期。
- 未提供、不合理或单位有歧义的字段明确留空，剩余时间排除系统未知哨兵值。

已覆盖 [coconutBattery 官方介绍](https://www.coconut-flavour.com/coconutbattery/) 中的主要 **Mac 本机电池**用途和本机可获取的寿命字段。尚未实现 iPhone / iPad 连接、自定义 HTML 打印模板和完整 SSD 生命周期累计读写；不宣称各机型都能读取相同字段。

## 低负担与数据保留

| 场景 | 默认行为 |
| --- | --- |
| 监测界面可见 | 每 2 秒调度，只读当前页面需要的模块 |
| 收起、完全遮挡或最小化 | 通常每 30 秒仅更新所选菜单栏指标 |
| 低电量模式 / 较高热压力 | 展开最快 5 秒，后台最快 60 秒 |
| 休眠 / 熄屏 | 暂停周期监测 |
| 深度报告、进程、扫描、测速 | 点击后才运行，关窗取消任务并释放结果 |
| 仅图标，摘要与提醒均关闭 | 没有周期采样 |

磁盘容量每分钟最多一次，电芯电压最快 10 秒，非散热页面的电池温度最快 5 秒。临时风扇控制有独立保护检查。

**App 不联网、不写原始采样日志、不建数据库。** 每组趋势最多 60 个点，仅保留在内存，监测窗口全部收起时清空。设置使用 macOS 偏好系统。

唯一可选历史是每日电池容量摘要：**默认关闭，每日一条，最多 90 条、64 KiB**。路径为 `~/Library/Application Support/OpenSensei/battery-daily.json`，设置中可清除。

目录扫描限制时间、文件数和结果数。磁盘测速的 32 MiB 临时文件创建后立即 unlink，描述符关闭后回收。不自动清理全盘。

## 风扇控制

SMC 实现参考 MIT 项目 [asdfghklddd/fanctl](https://github.com/asdfghklddd/fanctl)。只有手动开始临时会话才请求管理员授权，不安装特权常驻服务，不保存密码。

会话包括截止时间、心跳、温度保护、写入验证和恢复自动控制。按 **⌘.** 或点击恢复按钮可结束。温控曲线平滑温度，并逐步降低转速。已在 **M1 Pro / macOS 27** 做过实机验证，其他机型仍需验证，见[验证范围](VALIDATION.md)和[第三方声明](THIRD_PARTY_NOTICES.txt)。

## 从源码构建

需要 Mac 和 Xcode 或兼容的 Swift 开发工具。部署目标为 macOS 14，Swift tools version 为 5.9，无外部 Swift 包依赖。

```sh
git clone https://github.com/asdfghklddd/open-sensei.git
cd open-sensei
./scripts/build.sh
./scripts/package-dmg.sh
```

构建使用仓库中的 PNG 图标、ImageIO 和系统 `iconutil`，不需要 AI 服务。App 输出到 `build/`，DMG 和校验文件输出到 `dist/`。默认按构建机器架构编译；当前发行包为 arm64。打包脚本不会覆盖已存在的 DMG。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox
./scripts/test-helper.sh
```

风扇集成测试使用模拟 SMC，不改变真实风扇转速。项目结构与贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 1.2 版本

- 全新 AI 生成图标，接入标准 macOS ICNS。
- 拖拽式 DMG、SHA-256 校验和中英双语文档。
- 包含 1.1 的电池寿命报告、打印、图表与按需采样改进。

当前为本地签名版本，跨机器兼容与公证尚待完善。本次已补完原生深色电池界面复查；测试范围与性能口径见 [VALIDATION.md](VALIDATION.md)。

## 许可证与参考

采用 [MIT 许可证](LICENSE)，保留 [SMC 第三方声明](THIRD_PARTY_NOTICES.txt)。电池字段的位置和语义参考 [WhatBattery](https://github.com/darrylmorley/whatbattery)，未增加运行依赖。图标生成方式与提示词见 [assets/README.md](assets/README.md)。
