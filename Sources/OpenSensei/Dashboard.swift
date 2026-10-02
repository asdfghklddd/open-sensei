import SwiftUI
import AppKit

private let mint = SenseiTheme.accent
private let muted = SenseiTheme.secondary

/// A compact instrument panel. All readings reuse the monitor's existing demand;
/// tiny trends share the value rows; expanded tools live in the management window.
struct Dashboard: View {
    @AppStorage("appearance") private var appearance = "system"
    @ObservedObject var monitor: Monitor
    var togglePin: () -> Void
    var close: () -> Void
    var collapse: () -> Void
    var openPage: (CenterPage) -> Void
    private var s: Snapshot { monitor.snapshot }
    private static let updateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            statusStrip
            ForEach(monitor.dashboardOrder) { module in
                switch module {
                case .cpu: cpuCard
                case .memoryStorage: VStack(spacing: 4) { memoryCard; diskCard }
                case .gpu: if monitor.showGPU { gpuRow }
                case .network: if monitor.showNetwork { networkCard }
                case .battery: if monitor.showBattery { batteryCard }
                }
            }
            footer
        }
        .padding(10)
        .frame(width: 400)
        .background(SenseiTheme.background)
        .foregroundStyle(Color.primary)
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 25, height: 25).accessibilityHidden(true)
            Text("Open Sensei").font(.system(size: 14, weight: .semibold, design: .rounded)).fixedSize()
            Text(monitor.chip.replacingOccurrences(of: "Apple ", with: "") + " · \(ProcessInfo.processInfo.activeProcessorCount) 核")
                .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: togglePin) {
                Image(systemName: monitor.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(monitor.pinned ? mint : muted).frame(width: 25, height: 26)
            }.buttonStyle(.plain).help(monitor.pinned ? "取消固定，回到菜单栏" : "固定为悬浮面板")
                .accessibilityLabel(monitor.pinned ? "取消固定" : "固定悬浮面板")
            Menu {
                Section("刷新频率") {
                    ForEach([1.0, 2.0, 5.0], id: \.self) { value in
                        Button("\(monitor.interval == value ? "✓ " : "")每 \(Int(value)) 秒") { monitor.setInterval(value) }
                    }
                }
                Divider()
                Button("设置与隐私") { openPage(.settings) }
                Button("打开管理窗口") { openPage(.overview) }
                Button("打开活动监视器") { openActivityMonitor() }
                Button("退出 Open Sensei") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(muted).frame(width: 22, height: 26)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("设置")
            if monitor.pinned {
                Button(action: collapse) {
                    Image(systemName: "sidebar.right").frame(width: 23, height: 26)
                }.buttonStyle(.plain).foregroundStyle(muted).help("贴边收起").accessibilityLabel("贴边收起面板")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 23, height: 26)
                }.buttonStyle(.plain).foregroundStyle(muted).help("隐藏面板").accessibilityLabel("隐藏面板")
            }
        }.padding(.bottom, 1)
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Button { openPage(.cooling) } label: {
                HStack(spacing: 5) {
                    Image(systemName: s.stamps.isEmpty ? "clock" : (s.thermal == .nominal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                    Text(thermalLabel)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                }.foregroundStyle(thermalColor)
            }.buttonStyle(.plain).help("打开温度与风扇详情；热压力由 macOS 提供")
            Spacer(minLength: 4)
            if monitor.lowPower { Image(systemName: "leaf.fill").foregroundStyle(mint).help("低电量模式，已降低刷新频率") }
            Text("\(Int(monitor.effectiveInterval ?? monitor.interval)) 秒")
            Text("·")
            Text(s.stamps.isEmpty ? "等待采样" : Self.updateTime.string(from: s.updated))
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .help("最近完成一轮采样的时间。不同指标按各自频率刷新，存储容量每 60 秒最多读取一次。")
    }

    private var cpuCard: some View {
        Button { openPage(.processes) } label: {
            HStack(spacing: 8) {
                moduleTitle("CPU", icon: "cpu", color: mint).frame(width: 51, alignment: .leading)
                reading(Format.percent(s.cpu), unit: "%", size: 25).frame(width: 61, alignment: .leading)
                CompactTrend(values: monitor.cpuHistory, color: mint, ceiling: 1,
                             available: s.stamps[.cpu]?.condition != .unavailable)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .help("CPU 最近最多 60 个采样点，纵轴 0–100%；收起后清空。")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("热点").font(.system(size: 10)).foregroundStyle(muted)
                    if monitor.showTemperatures {
                        reading(s.sensors.hottest.map { String(format: "%.1f", $0) } ?? "—", unit: "°C", size: 17)
                    } else {
                        Text("已关闭").font(.system(size: 10)).foregroundStyle(muted)
                    }
                }.fixedSize()
                chevron
            }
        }.buttonStyle(DashboardCardStyle(color: mint))
            .help("CPU 总使用率、近期趋势与核心热点。点击查看资源进程。")
    }

    private var memoryCard: some View {
        Button { openPage(.overview) } label: {
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    moduleTitle("内存", icon: "memorychip", color: .purple).frame(width: 51, alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        reading(s.memoryUsed.map { String(format: "%.1f", $0 / 1_073_741_824) } ?? "—", unit: "/ \(Int(s.memoryTotal / 1_073_741_824)) GB", size: 20)
                    }
                    SegmentedLevel(value: s.memoryUsed == nil ? nil : s.memoryFraction, color: .purple)
                        .frame(maxWidth: .infinity).frame(height: 6)
                    Text("压力 \(s.memoryPressure)").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(memoryPressureColor).fixedSize()
                    chevron
                }
                HStack(spacing: 0) {
                    detail("App", value: memoryAmount(s.appMemory))
                    Spacer(minLength: 4)
                    detail("联动", value: memoryAmount(s.wiredMemory))
                    Spacer(minLength: 4)
                    detail("压缩", value: memoryAmount(s.memoryUsed == nil ? nil : s.compressed))
                    Spacer(minLength: 4)
                    detail("交换", value: memoryAmount(s.swap))
                }.font(.system(size: 10)).monospacedDigit().lineLimit(1)
            }
        }.buttonStyle(DashboardCardStyle(color: .purple))
            .help("内存按 1024 进制显示。已用内存 = App + 联动 + 压缩。占用率不等于内存压力；交换空间不计入已用物理内存。点击查看构成。")
    }

    private var diskCard: some View {
        Button { openPage(.storage) } label: {
            HStack(spacing: 8) {
                moduleTitle("存储", icon: "internaldrive", color: .orange).frame(width: 51, alignment: .leading)
                reading(s.diskFree.map { String(format: "%.0f", $0 / 1_000_000_000) } ?? "—", unit: "GB 可用", size: 20)
                SegmentedLevel(value: s.diskTotal == nil || s.diskFree == nil ? nil : s.diskFraction, color: .orange)
                    .frame(maxWidth: .infinity).frame(height: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("已用 \(Format.percent(s.diskTotal == nil || s.diskFree == nil ? nil : s.diskFraction))%")
                    Text("共 \(s.diskTotal.map { Format.bytes($0) } ?? "—")").foregroundStyle(muted)
                }.font(.system(size: 10)).monospacedDigit().fixedSize()
                chevron
            }
        }.buttonStyle(DashboardCardStyle(color: .orange))
            .help("用户目录所在卷的可用空间，不含系统可清除空间。点击打开空间整理。")
    }

    private var gpuRow: some View {
        Button { openPage(.overview) } label: {
            HStack(spacing: 8) {
                moduleTitle("GPU", icon: "square.stack.3d.up", color: .blue).frame(width: 51, alignment: .leading)
                Text(s.gpu.map { "\(Format.percent($0))%" } ?? (s.stamps[.gpu] == nil ? "等待采样" : "未提供"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().fixedSize()
                SegmentedLevel(value: s.gpu, color: .blue).frame(maxWidth: .infinity).frame(height: 6)
                Text("总占用").font(.system(size: 10)).foregroundStyle(muted)
                chevron
            }
        }.buttonStyle(DashboardCardStyle(color: .blue))
            .help("GPU 总使用率；分段条范围 0–100%。")
    }

    private var networkCard: some View {
        Button { openPage(.activity) } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 4) {
                    moduleTitle("网络", icon: "network", color: .blue)
                    Text(monitor.networkInterface == "all" ? "en* 合计" : monitor.networkInterface)
                        .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                }.frame(width: 56, alignment: .leading)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 35)
                VStack(spacing: 5) {
                    networkValue("下载", symbol: "arrow.down", value: s.network.download, values: monitor.downloadHistory, color: mint)
                    networkValue("上传", symbol: "arrow.up", value: s.network.upload, values: monitor.uploadHistory, color: .blue)
                }
                chevron
            }
        }.buttonStyle(DashboardCardStyle(color: .blue))
            .help("实时速率与各自最近最多 60 个采样点；上传、下载曲线各自缩放。点击查看完整网络活动。")
    }

    private func networkValue(_ title: String, symbol: String, value: Double, values: [Double], color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                .accessibilityLabel(title)
            Text(s.stamps[.network]?.condition == .ready ? Format.rate(value) : "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85).frame(width: 99, alignment: .leading)
            CompactTrend(values: values, color: color, ceiling: max(1024, values.max() ?? 0),
                         available: s.stamps[.network]?.condition != .unavailable)
                .frame(maxWidth: .infinity).frame(height: 16)
        }
    }

    private var batteryCard: some View {
        Button { openPage(.hardware) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    moduleTitle("电池", icon: s.battery?.charging == true ? "bolt.fill" : "battery.100percent", color: batteryColor)
                        .frame(width: 51, alignment: .leading)
                    reading(s.battery.map { Format.percent($0.percent) } ?? "—", unit: "%", size: 20)
                    SegmentedLevel(value: s.battery?.percent, color: batteryColor)
                        .frame(maxWidth: .infinity).frame(height: 6)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(batteryState).foregroundStyle(Color.primary)
                        Text(batterySubtitle).foregroundStyle(muted)
                    }.font(.system(size: 10)).lineLimit(1).frame(width: 128, alignment: .trailing)
                    chevron
                }
                HStack(spacing: 0) {
                    Text(s.health.batteryPower.map { String(format: "%@ %.1f W", s.health.powerLabel, abs($0)) } ?? "电池功率 —")
                    Spacer(minLength: 4)
                    Text(s.health.temperature.map { String(format: "%.1f°C", $0) } ?? "— °C")
                    Spacer(minLength: 4)
                    Text(s.health.voltage.map { String(format: "%.2f V", $0) } ?? "— V")
                    Spacer(minLength: 4)
                    Text(s.health.cycles.map { "\($0) 次循环" } ?? "循环 —")
                }.font(.system(size: 10)).monospacedDigit().foregroundStyle(muted).lineLimit(1)
            }
        }.buttonStyle(DashboardCardStyle(color: batteryColor))
            .help("\(batterySubtitle)。电池端功率 = 电压 × 电流，与整机输入功率不同。点击查看电池健康、电芯与硬件详情。")
    }

    private func memoryAmount(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func detail(_ title: String, value: String) -> some View {
        HStack(spacing: 3) { Text(title).foregroundStyle(muted); Text(value) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openPage(.overview) } label: {
                Label("管理中心", systemImage: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(mint)
            Spacer()
            Text("收起后降低采样").font(.system(size: 10)).foregroundStyle(muted)
            Button { openPage(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 12)).frame(width: 24, height: 22)
            }.buttonStyle(.plain).foregroundStyle(muted).help("设置与隐私").accessibilityLabel("设置与隐私")
        }.padding(.top, 1)
    }

    private func moduleTitle(_ title: String, subtitle: String? = nil, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).fontWeight(.semibold)
            if let subtitle { Text(subtitle).foregroundStyle(muted).font(.system(size: 10)) }
        }.font(.system(size: 11)).lineLimit(1)
    }
    private func reading(_ value: String, unit: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded))
            Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
        }.monospacedDigit().fixedSize()
    }
    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(muted.opacity(0.65)).accessibilityHidden(true)
    }
    private var batteryState: String {
        guard let battery = s.battery else { return s.stamps[.battery] == nil ? "等待采样" : "未提供" }
        return battery.charging ? "充电中" : (battery.pluggedIn ? "外接电源" : "电池供电")
    }
    private var batterySubtitle: String {
        guard let battery = s.battery else { return s.stamps[.battery] == nil ? "正在读取电源状态" : "当前设备未报告内置电池" }
        if battery.charging || !battery.pluggedIn { return battery.timeLabel }
        return battery.percent >= 0.99 ? "已充满" : "已连接 · 暂未充电"
    }
    private var batteryColor: Color { (s.battery?.percent ?? 1) <= 0.2 ? .orange : mint }
    private var memoryPressureColor: Color {
        switch s.memoryPressure { case "正常": return mint; case "偏高": return .orange; case "很高": return .red; default: return muted }
    }
    private var thermalLabel: String {
        guard !s.stamps.isEmpty else { return "正在采样" }
        switch s.thermal {
        case .nominal: return "散热正常"
        case .fair: return "轻度热压力"
        case .serious: return "较高热压力"
        case .critical: return "严重热压力"
        @unknown default: return "热压力未知"
        }
    }
    private var thermalColor: Color {
        guard !s.stamps.isEmpty else { return muted }
        switch s.thermal { case .nominal: return mint; case .critical: return .red; default: return .orange }
    }
}

private struct DashboardCardStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).fill(color.opacity(configuration.isPressed ? 0.10 : 0.025)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.17), lineWidth: 1).allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
    }
}

/// Reuses existing bounded samples. The compact variant omits grid lines and
/// draws only when a sample arrives; it has no animation or refresh timer.
private struct CompactTrend: View {
    let values: [Double]
    let color: Color
    let ceiling: Double
    let available: Bool
    var body: some View {
        ZStack {
            Sparkline(values: values, color: color, ceiling: ceiling, compact: true)
            if values.count < 2 {
                Text(available ? "采样中" : "未提供").font(.system(size: 10)).foregroundStyle(muted)
            }
        }
    }
}

/// Static, bounded drawing. No animation timer and no history buffer.
private struct SegmentedLevel: View {
    let value: Double?
    let color: Color
    var body: some View {
        Canvas { context, size in
            let count = max(1, min(24, Int(size.width / 7))), gap: CGFloat = 2
            let width = max(0, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            let fraction = ChartScale.fraction(value)
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: 1)
                context.fill(path, with: .color(Color.primary.opacity(0.08)))
                if let fraction {
                    let fill = min(1, max(0, fraction * Double(count) - Double(index)))
                    if fill > 0 {
                        var clipped = context
                        clipped.clip(to: Path(CGRect(x: rect.minX, y: 0, width: width * fill, height: size.height)))
                        clipped.fill(path, with: .color(color))
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}

struct Meter: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }.frame(height: 4)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    let ceiling: Double
    var compact = false
    var body: some View {
        Canvas { context, size in
            for fraction in (compact ? [] : [0.0, 0.5, 1.0]) {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                context.stroke(grid, with: .color(Color.primary.opacity(0.06)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
            guard values.count > 1 else { return }
            var path = Path()
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * Double(index) / Double(values.count - 1),
                        y: 2 + (size.height - 4) * (1 - min(1, max(0, value / max(1e-9, ceiling)))))
            }
            path.addLines(points)
            var area = path
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.23), color.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.accessibilityLabel("实时趋势，共 \(values.count) 个采样点")
    }
}

func openActivityMonitor() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
}
