# Open Sensei 1.2.4

## 中文

修复菜单栏图标被系统隐藏或难以识别的问题。

- 状态项明确保持可见，并使用适配浅色和深色菜单栏的模板波形图标。
- 图标旁显示 `Sensei · CPU xx%` 或当前选择的指标，方便确认它确实已经驻留在菜单栏。
- macOS 的“允许在菜单栏显示 → Open Sensei”已在本机打开；正式安装版已重启验证。
- 52 项 Swift 测试通过；没有增加采样循环、历史文件或特权服务。

## English

This release makes the menu-bar item easier to find and keeps it visible.

- The status item explicitly remains visible and uses a template waveform icon for light and dark menu bars.
- A readable `Sensei · CPU xx%` label, or the selected metric, appears beside the icon.
- macOS Menu Bar settings were enabled for Open Sensei and the installed app was restarted and checked.
- All 52 Swift tests passed. No new sampling loop, history file, or privileged service was added.

## Install / 安装

Quit the running copy before replacing it. Drag Open Sensei.app from the DMG into Applications, eject the image, then open the installed app. / 替换前先退出正在运行的副本。将 DMG 内的 App 拖入“应用程序”，推出映像，再打开已安装的 App。

If the icon is still hidden, open System Settings → Menu Bar → Allow in Menu Bar and enable Open Sensei. / 如果图标仍隐藏，请打开“系统设置 → 菜单栏 → 允许在菜单栏显示”，开启 Open Sensei。

Apple Silicon (arm64), macOS 14+. Ad-hoc signed; not Developer ID notarized. / 适用于 Apple Silicon，macOS 14 及以上；采用 ad-hoc 签名，尚未完成 Developer ID 公证。
