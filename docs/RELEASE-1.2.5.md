# Open Sensei 1.2.5

## 中文

修复临时风扇会话在恢复验证失败后一直锁定的问题，并提供明确的失败原因和重新恢复入口。

- 恢复自动模式后等待并轮询验证，单次最多 1 秒，避免硬件状态尚未更新就判断失败。已处于自动模式的风扇不重复写入。
- 恢复失败时提供“重新验证并恢复自动…”按钮。管理员授权后逐个验证和恢复风扇，全部确认成功才允许再次调速；取消或失败后仍可重试。
- 区分自动模式写入失败、回读失败和验证超时，并展示受影响风扇及系统、固件返回码。启动前和运行中的温度、模式、转速范围问题也提供具体提示。
- 按钮因传感器数据缺失而禁用时显示原因。
- 菜单栏使用紧凑的方形图标，实时读数保留在提示和面板中，减少菜单栏拥挤时图标被隐藏的机会。
- 保留原有温度保护、心跳、会话截止时间和结束后恢复机制，不安装常驻特权服务。

### 验证

53 项 Swift 测试及控制组件模拟测试通过，包括恢复延迟、写入拒绝、回读失败、验证超时、恢复重试和授权中断。发布构建通过签名验证。

在 Apple M1 Pro、macOS 27.0 上完成两轮实机验证：
1. 固定转速 40%：目标约 3,032 / 3,216 RPM，观察到实际约 3,020 / 3,222 RPM；手动结束后两只风扇均确认系统自动，开始按钮重新可用。
2. 温度曲线：观察到实际约 5,000 / 5,377 RPM，并随曲线调整；手动结束后两只风扇均确认系统自动，开始按钮重新可用。

实机验证覆盖正常调速和正常恢复；没有人为制造真实硬件恢复失败。故障恢复入口和错误分支通过模拟及状态测试验证。不能追溯旧版未记录的历史底层错误，也不保证所有机型和固件均支持控制。

## English

Fan sessions can now recover from an unconfirmed automatic-mode restoration instead of remaining locked for the rest of the app run.

- Poll automatic-mode readback for up to one second per attempt; avoid writes when automatic mode is already confirmed.
- Offer an administrator-authorized recovery action after a failure. Re-enable manual sessions only after all fans are confirmed restored; cancellation and failure remain retryable.
- Distinguish restoration write, readback, and verification failures, with fan numbers and system/firmware diagnostics. Explain missing sensor data and other control failures.
- Use a compact square menu-bar icon, with live readings retained in the tooltip and panel.
- Preserve thermal protection, heartbeat, bounded sessions, and restoration; no persistent privileged service is installed.

Validation: 53 Swift tests and helper simulations passed. Fixed-speed and temperature-curve sessions were tested on an Apple M1 Pro running macOS 27.0; both fans returned to confirmed automatic mode and the start button became available after each session. Real restoration failures were not deliberately induced; retry and error paths were validated with simulation/state tests.

## Install / 安装

Quit the running copy before replacing it. Drag Open Sensei.app from the DMG into Applications, eject the image, then open the installed app.

替换前先退出正在运行的副本。将 DMG 内的 App 拖入“应用程序”，推出映像，再打开已安装的 App。

Apple Silicon (arm64), macOS 14+. Ad-hoc signed; not Developer ID notarized.
