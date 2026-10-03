# Open Sensei 1.2.3

## 中文

修复安装后打开 App 缺少明显反馈的问题。

- 从“应用程序”手动启动或再次打开 App，会显示管理窗口。
- 点击菜单栏图标仍打开紧凑监测面板，关闭管理窗口后继续在菜单栏运行。
- 检测到已有副本时，将打开请求交给已有副本；如果转交失败，会说明如何找到或退出已有副本。
- 52 项 Swift 测试通过；正式安装版的启动、重开和重复启动已在 M1 Pro / macOS 27 上验证。
- 登录启动的识别逻辑、采样频率、历史保留和风扇控制保持原有行为；没有新增后台定时器或日志。

## English

Opening the installed app now gives clear visual feedback.

- Manual launch and reopen show the management window.
- The menu-bar icon still opens the compact monitor. Closing the management window keeps monitoring in the menu bar.
- A second copy forwards its open request to the running copy. A failed handoff displays instructions for finding or quitting the existing copy.
- All 52 Swift tests passed. Installed launch, reopen and duplicate launch were checked on M1 Pro / macOS 27.
- Login-item detection, sampling, history limits and fan control retain their existing behavior. No new background timers or logs.

Validation scope: [VALIDATION.md](https://github.com/asdfghklddd/open-sensei/blob/main/VALIDATION.md).

## Install / 安装

Quit the running copy before replacing it. Drag Open Sensei.app from the DMG into Applications, eject the image, then open the installed app. / 替换前先退出正在运行的副本。将 DMG 内的 App 拖入“应用程序”，推出映像，再打开已安装的 App。

Apple Silicon (arm64), macOS 14+. Ad-hoc signed; not Developer ID notarized. / 适用于 Apple Silicon，macOS 14 及以上；采用 ad-hoc 签名，尚未完成 Developer ID 公证。
