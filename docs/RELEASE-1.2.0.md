# Open Sensei 1.2.0

## English

Native macOS system monitor and maintenance app with a new original app icon and a drag-and-drop DMG.

- CPU, memory, GPU where available, battery, sensors, fan monitoring, network and disk activity.
- Mac battery deep reports: system health, controller lifetime fields, bank learning capacity, power input, and printable summaries.
- Temporary, explicitly authorized fan control with restore/deadline/heartbeat protection.
- Bounded storage tools, optional alerts, no network requests, and no raw monitoring history on disk.
- English and Chinese repository documentation. The app interface is currently primarily Chinese.

**Install:** download the arm64 DMG, drag the app to Applications, eject the image, then launch the app. Requires Apple Silicon and macOS 14+.

**Signing:** ad-hoc signed, not Developer ID notarized. macOS may require your approval in Privacy & Security. Verify the source and `SHA256SUMS` before opening.

52 Swift tests, 9 simulated fan-session tests, SMC checks, icon conversion, native UI checks, DMG verification, and mounted-app signature/hash checks passed. Physical coverage is currently M1 Pro / macOS 27; other machines and versions need further testing.

## 简体中文

原生 Mac 系统监测与管理 App，本版加入专属图标及拖拽式 DMG 安装包。

- CPU、内存、可获取的 GPU、电池、温度、风扇、网络和磁盘活动。
- Mac 电池深度报告：系统健康、控制器寿命字段、电芯组学习容量、实时供电与可打印摘要。
- 需要明确授权的临时风扇控制，包含恢复、截止时间和心跳保护。
- 有预算的存储工具、可选提醒、不联网、不保存原始监测历史。
- 仓库提供中英双语文档，App 界面当前以中文为主。

**安装：**下载 arm64 DMG，将 App 拖到 Applications，推出磁盘映像后启动。需要 Apple Silicon 和 macOS 14+。

**签名：**当前使用 ad-hoc 签名，尚未通过 Developer ID 公证；macOS 可能要求在“隐私与安全性”中由你允许打开。请先核对来源与 `SHA256SUMS`。

52 项 Swift 测试、9 项模拟风扇会话、SMC 校验、图标转换、原生界面、DMG 和挂载后签名 / 哈希检查通过。实机覆盖 M1 Pro / macOS 27，其他设备和系统仍需验证。
