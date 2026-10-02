# Open Sensei 1.2.2

## 中文

这次压缩卡片内部留白，将首屏改为紧凑指标行。完整默认面板从 400 × 569 点缩为 400 × 406 点，高度再减少约 29%。

- CPU 用量、趋势与热点温度排在同一行，上传与下载速率旁恢复迷你折线图。
- 内存改为横向读数，并直接展示 App、联动、压缩和交换；内存分项与总量统一采用 1024 进制。
- 存储、GPU 和电池的容量条填充剩余宽度，分段数量自适应窄空间；电池增加电压显示。
- 缩小标题区、卡片内边距和模块间距，保留独立点击区域。
- 固定、贴边收起、恢复及取消固定已在本机验证。
- 使用已有采样和最多 60 点的内存历史；没有新增硬件读取、日志文件或动画定时器。

## English

The panel now uses compact metric rows with less empty space inside each card. The complete default layout is 400 × 406 points, about 29% shorter than the 400 × 569 layout in 1.2.1.

- CPU load, a mini trend and hotspot temperature share one row. Upload/download mini trends return beside their rates.
- Memory includes App, wired, compressed and swap figures using consistent binary units.
- Load/capacity bars use available width and adapt their segment count to narrow spaces. Battery voltage is visible.
- Header, padding and module gaps are smaller while rows remain individually clickable.
- Pin, edge collapse, expansion and unpin were checked on the physical Mac.
- Existing sampling and bounded 60-point histories are reused. No new hardware reads, history files or animation timers.

Validation and performance scope: [VALIDATION.md](https://github.com/asdfghklddd/open-sensei/blob/main/VALIDATION.md).

## Install / 安装

Quit the old app, open the DMG and drag Open Sensei.app to Applications to replace it. / 退出旧版，打开 DMG，将 App 拖入“应用程序”并替换。

Apple Silicon (arm64), macOS 14+. Ad-hoc signed; not Developer ID notarized. / 适用于 Apple Silicon，macOS 14 及以上；采用 ad-hoc 签名，尚未完成 Developer ID 公证。
