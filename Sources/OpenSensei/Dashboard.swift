import SwiftUI
import AppKit

private let mint = SenseiTheme.accent
private let lavender = Color(red: 0.72, green: 0.68, blue: 0.96)
private let muted = SenseiTheme.secondary

struct Dashboard: View {
    @AppStorage("appearance") private var appearance = "system"
    @ObservedObject var monitor: Monitor
    var togglePin: () -> Void
    var close: () -> Void
    var collapse: () -> Void
    var openCenter: () -> Void
    private var s: Snapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            header
            HStack(spacing: 6) {
                Circle().fill(mint).frame(width: 5, height: 5)
                Text(monitor.chip).lineLimit(1)
                Text("·")
                Text("\(ProcessInfo.processInfo.activeProcessorCount) 核心")
                Spacer()
                Text("实时").foregroundStyle(mint)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            ForEach(monitor.dashboardOrder) { module in
                switch module {
                case .cpu: cpuCard
                case .memoryStorage: HStack(spacing: 10) { memoryCard; diskCard }
                case .gpu:
                    if monitor.showGPU {
                        HStack {
                            Label("GPU", systemImage: "square.stack.3d.up")
                            Spacer()
                            Text(s.gpu.map { "\(Format.percent($0))%" } ?? "驱动未提供").monospacedDigit().foregroundStyle(mint)
                        }.font(.system(size: 11)).padding(.horizontal, 3)
                    }
                case .network: if monitor.showNetwork { networkCard }
                case .battery:
                    if monitor.showBattery {
                        batteryRow
                        if let temp = s.health.temperature {
                            HStack {
                                Label(String(format: "电池 %.1f°C", temp), systemImage: "thermometer.medium")
                                Spacer()
                                if let power = s.health.batteryPower { Text(String(format: "%@ %.1f W", s.health.powerLabel, abs(power))) }
                            }.font(.system(size: 11)).foregroundStyle(muted)
                        }
                    }
                }
            }
            footer
        }
        .padding(22)
        .frame(width: 384)
        .background {
            ZStack(alignment: .topLeading) {
                SenseiTheme.background
                RadialGradient(colors: [mint.opacity(0.09), .clear], center: .topLeading, startRadius: 0, endRadius: 330)
            }
        }
        .foregroundStyle(Color.primary)
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(mint.opacity(0.12)).frame(width: 36, height: 36)
                Image(systemName: "waveform.path").font(.system(size: 19, weight: .medium)).foregroundStyle(mint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Open Sensei").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("你的 Mac，一目了然").font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer()
            Button(action: togglePin) {
                Image(systemName: monitor.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(monitor.pinned ? mint : muted)
                    .frame(width: 26, height: 28)
            }.buttonStyle(.plain).help(monitor.pinned ? "取消固定，回到菜单栏" : "固定为悬浮面板")
                .accessibilityLabel(monitor.pinned ? "取消固定" : "固定悬浮面板")
            Menu {
                Section("刷新频率") {
                    ForEach([1.0, 2.0, 5.0], id: \.self) { value in
                        Button("\(monitor.interval == value ? "✓ " : "")每 \(Int(value)) 秒") { monitor.setInterval(value) }
                    }
                }
                Divider()
                Button("打开管理窗口") { openCenter() }
                Button("打开活动监视器") { openActivityMonitor() }
                Button("退出 Open Sensei") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(muted).frame(width: 22, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("设置")
            if monitor.pinned {
                Button(action: collapse) { Image(systemName: "sidebar.right").font(.system(size: 12)).foregroundStyle(muted) }.buttonStyle(.plain).help("贴边收起").accessibilityLabel("贴边收起面板")
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(muted) }
                    .buttonStyle(.plain).help("隐藏面板")
            }
        }
    }

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("处理器", systemImage: "cpu").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(thermalLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(thermalColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(thermalColor.opacity(0.10), in: Capsule())
            }
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(Format.percent(s.cpu)).font(.system(size: 43, weight: .medium, design: .rounded))
                        Text("%").font(.system(size: 17, weight: .light)).foregroundStyle(muted)
                    }.monospacedDigit()
                    Text(s.cpu == nil ? "正在采样…" : "CPU 使用率").font(.system(size: 10)).foregroundStyle(muted)
                }.frame(width: 100, alignment: .leading)
                Sparkline(values: monitor.cpuHistory, color: mint, ceiling: 1)
                    .frame(height: 59)
            }
            HStack {
                if monitor.showTemperatures { Text(s.sensors.hottest.map { String(format: "核心热点 %.1f°C", $0) } ?? (s.stamps[.thermal] == nil ? "正在读取温度" : "温度接口未提供")) }
                else { Text("温度采集已关闭") }
                Spacer()
                Text("\(Int(monitor.effectiveInterval ?? monitor.interval)) 秒刷新")
            }.font(.system(size: 10)).foregroundStyle(muted)
        }.padding(15).card()
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("内存", systemImage: "memorychip").font(.system(size: 11, weight: .medium))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(s.memoryUsed.map { String(format: "%.1f", $0 / 1_073_741_824) } ?? "—")
                    .font(.system(size: 27, weight: .light, design: .rounded))
                Text("GB").font(.system(size: 10)).foregroundStyle(muted)
            }.monospacedDigit()
            Meter(value: s.memoryFraction, color: lavender)
            Text("共 \(Int(s.memoryTotal / 1_073_741_824)) GB · 已用 \(Format.percent(s.memoryUsed == nil ? nil : s.memoryFraction))%")
                .font(.system(size: 10)).foregroundStyle(muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
            .help("App 内存 + 联动内存 + 压缩内存。已压缩 \(Format.bytes(s.compressed))；占用率不等于内存压力。")
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("存储", systemImage: "internaldrive").font(.system(size: 11, weight: .medium))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(s.diskFree.map { String(format: "%.0f", $0 / 1_000_000_000) } ?? "—")
                    .font(.system(size: 27, weight: .light, design: .rounded))
                Text("GB").font(.system(size: 10)).foregroundStyle(muted)
            }.monospacedDigit()
            Meter(value: s.diskFraction, color: Color(red: 0.91, green: 0.77, blue: 0.53))
            Text("可用空间 · 已用 \(Format.percent(s.diskTotal == nil ? nil : s.diskFraction))%")
                .font(.system(size: 10)).foregroundStyle(muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
            .help("用户目录所在卷的可用空间，不含系统可清除空间。")
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("网络", systemImage: "network").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(monitor.networkInterface == "all" ? "en* 接口合计" : monitor.networkInterface).font(.system(size: 10)).foregroundStyle(muted)
            }
            HStack(spacing: 16) {
                networkColumn(symbol: "arrow.down", title: "下载", value: s.network.download, values: monitor.downloadHistory, color: mint)
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1, height: 54)
                networkColumn(symbol: "arrow.up", title: "上传", value: s.network.upload, values: monitor.uploadHistory, color: lavender)
            }
        }.padding(15).card()
    }

    private func networkColumn(symbol: String, title: String, value: Double, values: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(muted)
                Spacer()
            }.font(.system(size: 10))
            Text(s.stamps[.network]?.condition == .ready ? Format.rate(value) : "—").font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
            Sparkline(values: values, color: color, ceiling: max(1024, values.max() ?? 0)).frame(height: 20)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: s.battery?.charging == true ? "battery.100percent.bolt" : "battery.75percent")
                .font(.system(size: 21)).foregroundStyle(mint)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.battery == nil ? "电源" : "电池").font(.system(size: 11, weight: .medium))
                Text(batterySubtitle).font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer()
            if let battery = s.battery {
                Text("\(Format.percent(battery.percent))%")
                    .font(.system(size: 20, weight: .light, design: .rounded)).monospacedDigit()
            } else {
                Text(s.stamps[.battery] == nil ? "正在读取" : "读数未提供").font(.system(size: 11)).foregroundStyle(muted)
            }
        }.padding(.horizontal, 3).padding(.vertical, 1)
    }

    private var footer: some View {
        VStack(spacing: 13) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            HStack {
                Button(action: openCenter) {
                    HStack(spacing: 5) {
                        Text("打开管理窗口")
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                    }.font(.system(size: 10)).foregroundStyle(muted)
                }.buttonStyle(.plain)
                Spacer()
                Text("收起后自动省电").font(.system(size: 10)).foregroundStyle(muted.opacity(0.8))
            }
        }
    }

    private var batterySubtitle: String {
        guard let battery = s.battery else { return "当前设备未报告内置电池" }
        if battery.charging {
            if let minutes = battery.remaining { return "正在充电 · 约 \(minutes) 分钟充满" }
            return "正在充电"
        }
        if battery.pluggedIn { return battery.percent >= 0.99 ? "已充满 · 电源已连接" : "电源已连接 · 未充电" }
        if let minutes = battery.remaining { return "电池供电 · 预计剩余 \(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "电池供电"
    }

    private var thermalLabel: String {
        switch s.thermal {
        case .nominal: return "散热状态正常"
        case .fair: return "轻度热压力"
        case .serious: return "较高热压力"
        case .critical: return "严重热压力"
        @unknown default: return "散热状态未知"
        }
    }
    private var thermalColor: Color { s.thermal == .nominal ? mint : .orange }
}

private extension View {
    func card() -> some View {
        background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.065), lineWidth: 1))
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
    var body: some View {
        Canvas { context, size in
            for fraction in [0.0, 0.5, 1.0] {
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
