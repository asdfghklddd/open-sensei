# Validation / 验证范围

Release: **1.2.0 / build 12**, 2026-10-02. Physical checks were performed on an Apple M1 Pro running macOS 27. The package targets macOS 14+, but this is not a claim of testing every supported version or Mac model.

## Automated checks

- **52 XCTest cases passed**: sampling schedules, missing values, battery field parsing, controller temperature units, manufacture-month validation, remaining-time sentinels, notification thresholds, report privacy/bounds, chart scales, storage budgets, cancellation, and existing diagnostics/tool logic.
- **9 simulated fan-session cases passed**: disconnect, curve behavior, termination signal, partial write failure, restore failure, another controller, missing temperature, heartbeat timeout, and deadline.
- C unit checks for SMC schema caching, fresh-value reads, invalidation, bounded eviction, fan bounds, encoding, preflight, and rollback passed.
- Standard ICNS conversion and reverse conversion passed. Finder displayed the actual generated icon.
- App and embedded helper passed `codesign --verify --deep --strict`; Info.plist and arm64 architecture were checked.
- The DMG passed `hdiutil verify`. Its mounted app passed signature verification and matched the source bundle's executable SHA-256. The Applications link resolves to `/Applications`.

## Native UI and hardware

Battery overview, capacity bars, cell-bank voltages, deep report, lifetime fields, report preview, native print preview, empty history state, memory composition, and storage rings have been checked. Version 1.2's dark battery UI was inspected, then appearance was restored to Follow System. The native print preview was canceled without printing.

Earlier fixed-speed and temperature-curve sessions were physically checked, then independently confirmed back in automatic mode. No manual fan session was started for packaging. Fans and sensors remain hardware-dependent. Notifications, login/logout, charger transitions, and other Mac models have not all been physically exercised.

## Performance methodology

CPU is measured using process CPU time divided by elapsed wall time, with one core equal to 100%. Memory uses `phys_footprint`. Short runs, cold launch, previously opened windows, thermal state, and locked-screen conditions are different scenarios and should not be treated as interchangeable benchmarks.

A single release-binary run on M1 Pro / macOS 27, after a 3-second warm-up:

| Phase | Elapsed | CPU (one core = 100%) | Physical footprint |
| --- | --- | --- | --- |
| Visible battery overview | 31.50 s | 1.854% | 46.89 MB |
| All windows closed | 36.75 s | 0.0159% | 44.39 MB |

The visible phase reported `visible=true`, with 16 battery, 6 battery-temperature, and 3 cell reads. The closed phase read CPU once and performed zero battery, temperature, or cell reads. Deep reports were not refreshed automatically. These are short, single-machine observations, not a cross-machine guarantee or a comparison against a commercial app.

中文：本次电池页展开实测约 31.50 秒，单核心口径 CPU 为 1.854%，物理内存 46.89 MB；关窗后约 36.75 秒，CPU 0.0159%，内存 44.39 MB，电池、温度和电芯均停止读取。这是单机短时样本，不作为跨机保证。

Local-only diagnostic records, machine-specific battery reports, build caches, and earlier working notes are intentionally excluded from this public repository. Reproduce measurements with the development flags `--profile-ui --profile-battery` or `--profile-idle-brief`; profiling modes exit when finished.

## Distribution limits

The release is **ad-hoc signed and not Developer ID notarized**. The published binary is arm64. Intel and other device/OS combinations need further testing. There is no claim that all coconutBattery or Sensei commercial features are reproduced. SSD lifetime totals, custom HTML print templates, and iPhone/iPad support are not included.

## 中文摘要

1.2 版本通过 52 项 Swift 测试、9 项模拟风扇会话测试及 C 侧校验。原生图标、DMG 完整性、签名、架构和挂载后的二进制一致性已检查；Finder 正确显示新图标。电池页面、报告、图表及深色外观已检查，测试后恢复跟随系统外观。

实机范围为 M1 Pro / macOS 27；其他设备、系统、实际通知投递和部分电源状态转换尚未完整覆盖。发行包采用 ad-hoc 签名，尚未公证。个人诊断、原始硬件记录和编译缓存不会发布到仓库。性能测试口径如上，不把短时样本当作所有 Mac 的保证。
