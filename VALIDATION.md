# Validation / 验证范围

Release: **1.2.2 / build 14**, 2026-10-02. Physical checks were performed on an Apple M1 Pro running macOS 27. The package targets macOS 14+, but this is not a claim of testing every supported version or Mac model.

## Automated checks

- **52 XCTest cases passed**: sampling schedules, missing values, battery field parsing, controller temperature units, manufacture-month validation, remaining-time sentinels, notification thresholds, report privacy/bounds, chart scales, storage budgets, cancellation, and existing diagnostics/tool logic.
- **9 simulated fan-session cases passed**: disconnect, curve behavior, termination signal, partial write failure, restore failure, another controller, missing temperature, heartbeat timeout, and deadline.
- C unit checks for SMC schema caching, fresh-value reads, invalidation, bounded eviction, fan bounds, encoding, preflight, and rollback passed.
- Standard ICNS conversion and reverse conversion passed. Finder displayed the actual generated icon.
- App and embedded helper passed `codesign --verify --deep --strict`; Info.plist and arm64 architecture were checked.
- The DMG passed `hdiutil verify`. Its mounted app passed signature verification and matched the source bundle's executable SHA-256. The Applications link resolves to `/Applications`.

## Dense metric rows (1.2.2)

- All 52 existing Swift tests passed again. Sampling and fan-control code were unchanged.
- The complete default panel now measures 400 × 406 points, about 29% shorter than 1.2.1. The minimal CPU/memory/storage panel is 400 × 251 points.
- CPU and network mini trends reuse existing 60-point RAM buffers. Memory exposes its components and swap using binary units consistently; battery voltage is also visible. Short load bars adapt their segment count to the available width.
- Native pin, edge collapse, expansion and unpin were verified, then the app was returned to menu-bar mode. Both appearances, unavailable readings, 100% loads, a large-memory configuration, low battery and long network-rate labels were rendered and inspected.
- No hardware polling, history files or animation timers were added.

## Compact panel update (1.2.1)

- All 52 existing Swift tests passed again. The fan helper and its controls were unchanged; the simulated fan checks above are from 1.2.0.
- Native CPU, network and battery card navigation was verified. Light/dark layouts, unavailable readings, 100% load, low charge, high thermal pressure, long rates, pin controls and disabled modules were rendered using fixtures.
- With all default modules, fitting size is 400 × 569 points, versus 384 × 719 for the prior panel, about 21% less height. The minimal CPU/memory/storage configuration is 400 × 342 points.
- The popover's line charts were removed; charts remain available in the management window. The UI reuses existing snapshot fields and introduces no hardware reads, history files or continuous animation timers.

## Native UI and hardware

Battery overview, capacity bars, cell-bank voltages, deep report, lifetime fields, report preview, native print preview, empty history state, memory composition, and storage rings have been checked. Version 1.2's dark battery UI was inspected, then appearance was restored to Follow System. The native print preview was canceled without printing.

Earlier fixed-speed and temperature-curve sessions were physically checked, then independently confirmed back in automatic mode. No manual fan session was started for packaging. Fans and sensors remain hardware-dependent. Notifications, login/logout, charger transitions, and other Mac models have not all been physically exercised.

## Performance methodology

CPU is measured using process CPU time divided by elapsed wall time, with one core equal to 100%. Memory uses `phys_footprint`. Short runs, cold launch, previously opened windows, thermal state, and locked-screen conditions are different scenarios and should not be treated as interchangeable benchmarks.

### 1.2.2 dense panel with mini trends

A completed release-binary run on M1 Pro / macOS 27 after a 3-second warm-up:

| Phase | Elapsed | CPU (one core = 100%) | Physical footprint |
| --- | --- | --- | --- |
| Visible dense panel | 30.63 s | 1.143% | 34.69 MB |
| All surfaces closed | 36.69 s | 0.0197% | 34.16 MB |

The visible phase reported `visible=true`; the closed phase reported `visible=false`, read CPU once and performed zero memory, GPU, network, battery, temperature or storage reads. An earlier run was excluded from idle reporting because its panel became visible again during that phase. These are short observations, not evidence of a speed improvement over 1.2.1.

中文：带迷你趋势的密集面板展开时，单核心 CPU 约 1.143%、物理内存 34.69 MB；正常收起后约 0.0197%、34.16 MB，仅刷新一次菜单栏 CPU。此前有一次待机阶段面板重新可见，该段不计作待机结果。

### 1.2.1 compact panel

A single release-binary run on M1 Pro / macOS 27 after a 3-second warm-up, with the dashboard pinned to keep it visible:

| Phase | Elapsed | CPU (one core = 100%) | Physical footprint |
| --- | --- | --- | --- |
| Visible compact panel | 30.66 s | 0.918% | 36.91 MB |
| All surfaces closed | 36.56 s | 0.0171% | 35.57 MB |

The visible phase reported `visible=true`. The closed phase read the menu-bar CPU metric once; memory, GPU, network, battery, temperature and storage reads were all zero. Memory after closing includes the process's prior UI allocations. This short observation is not a performance comparison with the older battery page or other apps.

中文：新版紧凑面板展开时，单核心口径 CPU 约 0.918%、物理内存 36.91 MB；收起后约 0.0171%、35.57 MB，仅读取一次菜单栏 CPU。不同页面与短时样本不能直接比较。

### Earlier 1.2.0 battery page

A single release-binary run on M1 Pro / macOS 27, after a 3-second warm-up:

| Phase | Elapsed | CPU (one core = 100%) | Physical footprint |
| --- | --- | --- | --- |
| Visible battery overview | 31.50 s | 1.854% | 46.89 MB |
| All windows closed | 36.75 s | 0.0159% | 44.39 MB |

The visible phase reported `visible=true`, with 16 battery, 6 battery-temperature, and 3 cell reads. The closed phase read CPU once and performed zero battery, temperature, or cell reads. Deep reports were not refreshed automatically. These are short, single-machine observations, not a cross-machine guarantee or a comparison against a commercial app.

中文：本次电池页展开实测约 31.50 秒，单核心口径 CPU 为 1.854%，物理内存 46.89 MB；关窗后约 36.75 秒，CPU 0.0159%，内存 44.39 MB，电池、温度和电芯均停止读取。这是单机短时样本，不作为跨机保证。

Local-only diagnostic records, machine-specific battery reports, build caches, and earlier working notes are intentionally excluded from this public repository. Reproduce measurements with the development flags `--profile-ui --profile-dashboard`, `--profile-ui --profile-battery`, or `--profile-idle-brief`; profiling modes exit when finished.

## Distribution limits

The release is **ad-hoc signed and not Developer ID notarized**. The published binary is arm64. Intel and other device/OS combinations need further testing. There is no claim that all coconutBattery or Sensei commercial features are reproduced. SSD lifetime totals, custom HTML print templates, and iPhone/iPad support are not included.

## 中文摘要

1.2.2 再次通过 52 项 Swift 测试；风扇部分未改动，沿用 1.2.0 的 9 项模拟会话测试及 C 侧校验。原生图标、DMG 完整性、签名、架构和挂载后的二进制一致性已检查；Finder 正确显示新图标。电池页面、报告、图表及深色外观已检查，测试后恢复跟随系统外观。

实机范围为 M1 Pro / macOS 27；其他设备、系统、实际通知投递和部分电源状态转换尚未完整覆盖。发行包采用 ad-hoc 签名，尚未公证。个人诊断、原始硬件记录和编译缓存不会发布到仓库。性能测试口径如上，不把短时样本当作所有 Mac 的保证。
