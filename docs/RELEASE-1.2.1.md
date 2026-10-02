# Open Sensei 1.2.1

## 中文

菜单栏首屏改为紧凑控制面板：默认高度从 719 点降至 569 点，减少约 21%。

- 用分段仪表取代首屏 CPU 和网络折线图，突出当前数值。
- 加强 CPU、内存、存储、GPU、网络和电池区的视觉区分。
- 展示已有的内存压力、交换空间、电池功率、温度和循环次数。
- 点击各卡片直接进入对应管理页；顶部显示热压力、采样频率和最近更新时间。
- 保留模块排序、显示开关、固定悬浮面板和贴边收起。
- 沿用现有采样规则，不新增硬件轮询、历史文件或常驻动画。

52 项现有 Swift 测试通过；检查了原生导航、深浅色、缺失读数和极值排版。详细方法和短时运行开销见 [VALIDATION.md](https://github.com/asdfghklddd/open-sensei/blob/main/VALIDATION.md)。

## English

The menu-bar popover is now a compact control panel. Its default height falls from 719 to 569 points, about 21% shorter.

- Segmented load and capacity bars replace the popover's CPU/network line charts.
- Distinct resource sections emphasize current readings, memory pressure, swap, and battery power, temperature and cycles.
- Cards open their corresponding management pages. The status strip shows thermal pressure, sampling cadence and the last update.
- Module ordering, visibility toggles, pinning and edge collapse remain available.
- Sampling rules are unchanged; no new hardware polling, history files or animation timers were added.

All 52 existing Swift tests passed. Native navigation, both appearances, unavailable readings and extreme-value layouts were checked. See [VALIDATION.md](https://github.com/asdfghklddd/open-sensei/blob/main/VALIDATION.md) for scope and short-run performance measurements.

## Install / 安装

Open the DMG, drag Open Sensei.app to Applications, and replace the earlier copy after quitting it. Preferences and optional battery summaries are retained. / 退出旧版，打开 DMG，将 App 拖到“应用程序”并替换。设置和可选的电池摘要会保留。

Apple Silicon (arm64), macOS 14+. Ad-hoc signed; not Developer ID notarized. / 适用于 Apple Silicon，macOS 14 及以上；采用 ad-hoc 签名，尚未完成 Developer ID 公证。
