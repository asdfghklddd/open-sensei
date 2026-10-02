# Contributing / 贡献指南

## Development

Use macOS 14+ and compatible Swift/Xcode tools. Clone this repository, run `./scripts/build.sh`, and open `build/Open Sensei.app`. The app has no third-party Swift package dependencies. The UI is currently primarily Chinese; English localization contributions are welcome.

- `Sources/OpenSensei`: SwiftUI/AppKit UI, sampling, battery reports, bounded local tools.
- `Sources/SMCCore`: SMC reads and validated fan writes.
- `Sources/FanHelper`: temporary authorized fan-control process.
- `Tests`: Swift unit tests.
- `scripts/tests`: C tests and simulated helper integration tests.
- `assets`: checked-in AI-generated icon and its provenance.

Run `swift test --disable-sandbox` and `./scripts/test-helper.sh` for changes to functionality. Test both appearances and missing-data states for UI work. Use `./scripts/package-dmg.sh` after building to create a DMG and checksum. Rebuild packages after every binary or resource change; do not alter a signed bundle after packaging.

## Project principles

Keep polling proportional to visible demand. Prefer one-shot tools to resident services. Bound retained data, work queues, scans, and file output. Unknown readings must remain unknown. Explain units and sources, particularly when system health and raw battery capacities differ.

Do not weaken fan bounds, thermal protection, heartbeats, deadlines, or restoration. Hardware tests are opt-in and must not run in CI. Simulation tests must not access real fan writes. Never store credentials, device serials, raw hardware dumps, or personal paths in commits or issue reports.

Please describe what changed, why it helps, how it was tested, and any hardware/OS limitations in a pull request. Contributions are under the MIT license; retain third-party notices.

## 中文

使用 macOS 14+ 与兼容的 Swift / Xcode 工具。执行 `./scripts/build.sh` 构建，执行 `swift test --disable-sandbox` 和 `./scripts/test-helper.sh` 验证功能。构建后使用 `./scripts/package-dmg.sh` 打包；资源或代码改变后必须重新签名打包。

保持按需采样、有限存储和明确的数据口径；缺失值不伪装成零。风扇保护、心跳、截止时间与恢复逻辑不能削弱。CI 只用模拟风扇测试，实机调节必须由操作者明确发起。

请勿提交凭据、设备序列号、原始硬件转储或私人路径。PR 应说明问题、实现、验证方法与兼容性边界。欢迎改善兼容性、可访问性和英文界面。
