import SwiftUI
import AppKit

enum SenseiTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.61, green: 0.89, blue: 0.72, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.43, blue: 0.30, alpha: 1)
    })
    static let background = Color(nsColor: .windowBackgroundColor)
    static let secondary = Color.primary.opacity(0.62)
}

struct ReadingTile: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    var color = SenseiTheme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(SenseiTheme.secondary)
            Text(value).font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.system(size: 11)).foregroundStyle(SenseiTheme.secondary).lineLimit(2).frame(minHeight: 27, alignment: .topLeading)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.13), lineWidth: 1))
            .accessibilityElement(children: .combine)
    }
}

struct CoolingView: View {
    let snapshot: Snapshot
    let history: ThermalHistory
    @ObservedObject var control: FanControl
    private var sensors: SensorSnapshot { snapshot.sensors }
    @State private var sensorQuery = ""
    @State private var sensorGroup = "全部"
    @State private var hottestFirst = false
    private var filteredSensors: [TemperatureReading] {
        sensors.temperatures.filter {
            (sensorGroup == "全部" || $0.group == sensorGroup) &&
            (sensorQuery.isEmpty || $0.id.localizedCaseInsensitiveContains(sensorQuery) || $0.group.localizedCaseInsensitiveContains(sensorQuery))
        }.sorted { hottestFirst && $0.value != $1.value ? $0.value > $1.value : $0.id < $1.id }
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ReadingTile(title: "核心热点", value: sensors.hottest.map { String(format: "%.1f °C", $0) } ?? "—", detail: "已读取 CPU / GPU 温度中的最高值", icon: "thermometer.medium", color: .orange)
                ReadingTile(title: "风扇控制", value: control.state.title(for: sensors), detail: control.status, icon: "fan", color: SenseiTheme.accent)
            }
            HStack(spacing: 16) {
                Text("温度").font(.system(size: 10)).foregroundStyle(.secondary)
                FreshnessLabel(snapshot: snapshot, domain: .thermal)
                Text("风扇").font(.system(size: 10)).foregroundStyle(.secondary)
                FreshnessLabel(snapshot: snapshot, domain: .fans)
            }
            if !sensors.available {
                Label("此设备的 SMC 传感器暂不可用。", systemImage: "info.circle").foregroundStyle(.secondary)
            } else if sensors.fans.isEmpty {
                Label(sensors.fanCount == 0 ? "硬件报告没有风扇。" : "风扇读数暂未返回，无法判断是否为无风扇机型。", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(sensors.fans) { fan in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("风扇 \(fan.id + 1)", systemImage: "fanblades").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(fan.modeLabel).font(.system(size: 11)).foregroundStyle(SenseiTheme.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.0f", fan.rpm)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("RPM").font(.system(size: 12)).foregroundStyle(SenseiTheme.secondary)
                        }
                        Meter(value: fan.maximum > 0 ? fan.rpm / fan.maximum : 0, color: SenseiTheme.accent)
                        HStack {
                            Text("范围 \(Int(max(0, fan.minimum)))–\(Int(max(0, fan.maximum))) RPM")
                            Spacer()
                            Text("目标 \(fan.target.map { String(format: "%.0f", $0) } ?? "—")")
                        }.font(.system(size: 10)).foregroundStyle(SenseiTheme.secondary)
                    }.senseiCard()
                }
            }
            FanControlPanel(fans: sensors.fans.filter(\.controllable).map(FanControlRange.init),
                            canStart: !sensors.fans.isEmpty && sensors.fans.allSatisfy(\.controllable) && sensors.hottest != nil,
                            control: control).equatable()
            ThermalTrendView(history: history)
            DisclosureGroup("传感器读数 · \(sensors.temperatures.count) 项") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("搜索传感器名称或键名", text: $sensorQuery).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("搜索传感器")
                        Toggle("温度从高到低", isOn: $hottestFirst).toggleStyle(.checkbox)
                    }
                    Picker("传感器分组", selection: $sensorGroup) {
                        ForEach(["全部", "CPU / 核心", "GPU", "电池"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("显示 \(filteredSensors.count) / \(sensors.temperatures.count) 项 · 组名按传感器键前缀归类")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if filteredSensors.isEmpty { Text("没有匹配的传感器").foregroundStyle(.secondary).padding(.vertical, 8) }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(filteredSensors) { sensor in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sensor.group).font(.system(size: 11))
                                Text(sensor.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(SenseiTheme.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1f°", sensor.value)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    }
                }.padding(.top, 12)
            }.font(.system(size: 12)).senseiCard()
        }
    }
}

private struct FanControlRange: Identifiable, Equatable {
    let id: Int
    let minimum: Double
    let maximum: Double
    init(_ reading: FanReading) { id = reading.id; minimum = reading.minimum; maximum = reading.maximum }
}

private struct FanControlPanel: View, Equatable {
    let fans: [FanControlRange]
    let canStart: Bool
    @ObservedObject var control: FanControl
    @State private var showingAuthorization = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fans == rhs.fans && lhs.canStart == rhs.canStart && lhs.control === rhs.control
    }
    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("临时散热会话", systemImage: "slider.horizontal.3").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if control.busy { Button(control.state.stopLabel) { control.stop() }.keyboardShortcut(".", modifiers: .command) }
                }
                Picker("调节方式", selection: $control.mode) {
                    ForEach(FanControlMode.allCases) { mode in Text(mode.label).tag(mode) }
                }.pickerStyle(.segmented).disabled(control.busy)
                Text(control.mode == .curve
                     ? "以 CPU / GPU 核心热点调节：55°C 以下保持基础转速，55–85°C 逐步加速。平滑温度、降温缓冲和缓慢降速可减少转速来回变化。"
                     : "按各风扇的硬件范围同步设置转速；核心热点超过 85°C 时会逐步加速，达到 95°C 时使用最高转速。")
                    .font(.system(size: 12)).foregroundStyle(SenseiTheme.secondary).fixedSize(horizontal: false, vertical: true)
                Text(control.mode == .curve ? "基础转速 · 占硬件可调范围" : "固定转速 · 占硬件可调范围")
                    .font(.system(size: 11)).foregroundStyle(SenseiTheme.secondary)
                HStack(spacing: 16) {
                    Slider(value: Binding(get: { control.percentage }, set: { control.percentage = $0.rounded() }), in: 0...100)
                        .accessibilityLabel("转速占硬件可调范围的比例")
                    Text("\(Int(control.percentage))%").font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 48)
                }.disabled(control.busy)
                HStack(spacing: 16) {
                    ForEach(fans) { fan in
                        Text("风扇 \(fan.id + 1)：\(Int((fan.minimum + (fan.maximum - fan.minimum) * control.percentage / 100).rounded())) RPM")
                    }
                }.font(.system(size: 11)).foregroundStyle(SenseiTheme.secondary)
                if control.mode == .curve {
                    HStack(spacing: 16) {
                        ForEach([55, 70, 85], id: \.self) { temperature in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(temperature)°C").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text("\(Int(control.percentage + (100 - control.percentage) * Double(temperature - 55) / 30))%")
                                    .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    Text("曲线按各风扇的最小 / 最大 RPM 换算。热点达到 95°C 时立即使用最高目标，不等待平滑；传感器失效会结束会话并恢复自动。")
                        .font(.system(size: 11)).foregroundStyle(SenseiTheme.secondary)
                }
                HStack {
                    Picker("持续时间", selection: $control.duration) {
                        Text("5 分钟").tag(300); Text("10 分钟").tag(600); Text("30 分钟").tag(1800)
                    }.frame(width: 190).disabled(control.busy)
                    Spacer()
                    if let date = control.endsAt {
                        Text("结束于 \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(SenseiTheme.secondary)
                    }
                    Button(control.busy ? "会话进行中" : "授权并开始…") { showingAuthorization = true }
                        .buttonStyle(.borderedProminent).disabled(control.busy || control.state.requiresRecovery || !canStart)
                }
                if let error = control.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let detail = control.state.detail {
                    Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .help("仅保存在本次会话内存中。stage 1：模式写入；2：目标写入；3：回读验证。")
                }
                Divider()
                Label("会话结束、退出 App、睡眠或连接中断后，控制组件会尝试恢复自动模式。组件仅在会话期间运行，不写日志；同时只使用一个风扇控制软件。", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 11)).foregroundStyle(SenseiTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }.senseiCard()
        .alert("开始临时散热会话？", isPresented: $showingAuthorization) {
            Button("取消", role: .cancel) {}
            Button("继续授权") { control.start() }
        } message: {
            Text("将以\(control.mode.label)调节所有风扇，持续 \(control.duration / 60) 分钟。macOS 会要求管理员授权。若其他软件正在调速，请先让它恢复自动模式。")
        }
    }
}
