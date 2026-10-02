import SwiftUI

struct BatteryDetailView: View {
    let snapshot: Snapshot
    @ObservedObject var details: BatteryDetailsModel
    let historyDays: [BatteryDay]
    let historyEnabled: Bool
    let historyBytes: Int
    let setHistory: (Bool) -> Void
    let lowPower: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section = "概览"
    @State private var reportText = ""
    @State private var showingReport = false
    private var h: BatteryHealth { snapshot.health }
    private func n(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "—" }
    private var powerState: String {
        snapshot.battery == nil ? "电池状态未提供" : h.charging ? "正在充电" : h.pluggedIn ? "已接电源 · 未充电" : "电池供电"
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            hero
            HStack {
                Picker("电池视图", selection: $section) {
                    Text("概览").tag("概览"); Text("深度报告").tag("深度报告"); Text("容量记录").tag("容量记录")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 285)
                Spacer()
                FreshnessLabel(snapshot: snapshot, domain: .battery)
            }
            Group {
                switch section {
                case "深度报告": deepReport
                case "容量记录": history
                default: overview
                }
            }.transition(.opacity)
        }
        .animation(reduceMotion || lowPower ? nil : .easeInOut(duration: 0.18), value: section)
        .sheet(isPresented: $showingReport) {
            SnapshotReportView(report: reportText, title: "电池报告", canPrint: true)
        }
    }
    private var hero: some View {
        HStack(spacing: 24) {
            ValueRing(fraction: snapshot.battery?.percent, value: "\(Format.percent(snapshot.battery?.percent))%", caption: "当前电量")
            VStack(alignment: .leading, spacing: 10) {
                Label(powerState, systemImage: h.pluggedIn ? "powerplug.fill" : "battery.75percent")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(SenseiTheme.accent)
                Text(snapshot.battery?.timeLabel ?? "内置电池读数未提供").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("\(h.cycles.map(String.init) ?? "—") 次循环")
                    Text(n(h.temperature, "%.1f°C"))
                }.font(.system(size: 12)).monospacedDigit()
                Text("剩余时间由系统估算，会随负载变化。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text("容量估算").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(n(h.capacityPercent, "%.1f%%")).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("标称满充 ÷ 设计容量").font(.system(size: 10)).foregroundStyle(.secondary)
                if let system = details.report?.systemCapacityPercent {
                    Text("系统报告 \(n(system, "%.0f%%"))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.senseiCard()
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ReadingTile(title: "电池温度", value: n(h.temperature, "%.1f °C"), detail: "当前电池传感器", icon: "thermometer.medium", color: .orange)
                ReadingTile(title: h.powerLabel, value: n(h.batteryPower.map(abs), "%.1f W"), detail: "\(n(h.voltage, "%.3f V")) · \(n(h.current, "%+.3f A"))", icon: "bolt.fill")
            }
            HStack(spacing: 8) { Text("温度"); FreshnessLabel(snapshot: snapshot, domain: .batteryTemperature); Spacer(); Text("电芯组"); FreshnessLabel(snapshot: snapshot, domain: .cells) }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            CapacityComparisonView(health: h)
            powerFlow
            CellBalanceView(values: snapshot.sensors.cells)
            DisclosureGroup("电源与控制器字段") {
                VStack(spacing: 10) {
                    HStack { Text("适配器档位"); Spacer(); Text("\(n(h.adapterVoltage, "%.2f V")) × \(n(h.adapterCurrent, "%.2f A"))").monospacedDigit() }
                    HStack { Text("永久故障状态码"); Spacer(); Text(h.failure.map(String.init) ?? "未提供").monospacedDigit() }
                    Text("状态码为 0 表示此字段没有报告永久故障，不能代替 macOS 的维修建议。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 11)).padding(.top, 10)
            }.font(.system(size: 12)).senseiCard()
            HStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 25)).foregroundStyle(SenseiTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("深入了解这块电池").font(.system(size: 14, weight: .semibold))
                    Text("系统健康、制造月份、累计工作时间、历史极值与学习容量。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("读取深度报告") { section = "深度报告"; details.refresh() }.buttonStyle(.borderedProminent).disabled(details.loading)
            }.senseiCard()
        }
    }
    private var powerFlow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("此刻的供电", systemImage: "bolt.horizontal.circle").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 15) {
                powerNode("电源适配器", h.pluggedIn ? n(h.adapterWatts, "%.0f W") : "未接入", "可用供电档位", "powerplug")
                VStack(spacing: 5) {
                    Text(n(h.inputPower, "%.1f W")).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    Image(systemName: "arrow.right").foregroundStyle(h.pluggedIn ? SenseiTheme.accent : .secondary)
                    Text("实时输入").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                powerNode("整机", "Mac", "按当前负载用电", "laptopcomputer")
                Image(systemName: (h.batteryPower ?? 0) < 0 ? "arrow.left" : "arrow.right")
                    .foregroundStyle(abs(h.batteryPower ?? 0) < 0.1 ? Color.secondary.opacity(0.4) : SenseiTheme.accent)
                powerNode("电池", n(h.batteryPower, "%+.1f W"), "正数充入 · 负数放出", "battery.75percent")
            }
            Text("适配器档位表示供电能力；实时输入供应整机和电池，不能当成电池充电功率。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.senseiCard()
    }
    private func powerNode(_ title: String, _ value: String, _ subtitle: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var deepReport: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("电池控制器与系统报告").font(.system(size: 14, weight: .semibold))
                    Text(details.report.map { "读取于 \($0.date.formatted(date: .omitted, time: .standard)) · 点击后才刷新" } ?? "按需读取，结果只保留在当前窗口内")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if details.loading { ProgressView().controlSize(.small); Button("取消") { details.cancel() } }
                Button(details.report == nil ? "读取报告" : "刷新报告") { details.refresh() }.disabled(details.loading)
                if let report = details.report {
                    Button("预览 / 打印…") { reportText = BatteryReportText.make(report, live: snapshot); showingReport = true }
                }
            }
            if let error = details.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 12)) }
            if let report = details.report {
                BatteryDeepValues(report: report).equatable()
            } else if !details.loading {
                ContentUnavailableView("无需常驻采集的深度信息", systemImage: "battery.100percent",
                    description: Text("读取控制器已有的寿命统计与系统健康报告。\n不会创建历史数据库，也不会修改充电行为。")).frame(height: 200)
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle("保留每日容量摘要", isOn: Binding(get: { historyEnabled }, set: setHistory))
                Spacer()
                Text("\(historyDays.count) / 90 天 · \(historyBytes) B").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("默认关闭。只记录每天一条容量比值与循环次数，文件最多 64 KiB；此图与控制器自带的寿命统计分开。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            BatteryDailyChart(days: historyDays).equatable()
            if !historyDays.isEmpty {
                DisclosureGroup("查看最近记录") {
                    ForEach(Array(historyDays.suffix(14).reversed().enumerated()), id: \.offset) { _, day in
                        HStack { Text(day.day); Spacer(); Text(String(format: "%.1f%%", day.capacity)); Text("\(day.cycles.map(String.init) ?? "—") 次循环").frame(width: 95, alignment: .trailing) }
                            .font(.system(size: 12)).monospacedDigit().padding(.vertical, 3)
                    }
                }.senseiCard()
            }
        }
    }
}

private struct BatteryDeepValues: View, Equatable {
    let report: BatteryDeepReport
    private func n(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "未提供" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ReadingTile(title: "系统最大容量", value: n(report.systemCapacityPercent, "%.0f%%"), detail: "macOS 健康报告 · \(report.conditionLabel)", icon: "checkmark.shield")
                ReadingTile(title: "累计工作时间", value: n(report.lifetime.operatingHours, "%.0f h"), detail: "控制器累计供电时间", icon: "clock", color: .blue)
            }
            Text("系统最大容量经过 macOS 的健康评估，口径可能与标称容量比值不同。累计时间不是剩余寿命或本软件运行时间。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            lifetime
            VStack(alignment: .leading, spacing: 14) {
                Label("设备与电池", systemImage: "info.circle").font(.system(size: 14, weight: .semibold))
                detail("Mac 型号", report.model ?? "未提供")
                detail("电池控制器", report.controller ?? "未提供")
                detail("制造月份（推算）", report.manufactureMonth ?? "编码未提供或无法验证")
                detail("固件 / 硬件版本", "\(report.firmware ?? "—") / \(report.hardwareRevision ?? "—")")
                detail("循环计数 / 设计参考", "\(report.cycles.map(String.init) ?? "—") / \(report.designCycles.map(String.init) ?? "—") 次")
                detail("永久故障状态码", report.failureCode.map(String.init) ?? "未提供")
                if let cycle = report.lifetime.lastCalibrationCycle { detail("最近学习容量时的循环", "\(cycle) 次") }
                Text("制造月份依据控制器字段解码。设计循环数是参考；故障码 0 表示该字段未报告永久故障，均不代替系统维修建议。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.senseiCard()
            if !report.banks.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Label("电芯组学习容量", systemImage: "battery.100percent").font(.system(size: 14, weight: .semibold))
                    ForEach(report.banks) { bank in
                        HStack {
                            Text("电芯组 \(bank.id + 1)")
                            Spacer()
                            Text(n(bank.volts, "%.3f V")).frame(width: 90, alignment: .trailing)
                            Text(n(bank.learnedCapacity, "%.0f mAh")).frame(width: 95, alignment: .trailing)
                        }.font(.system(size: 12)).monospacedDigit()
                    }
                    Text("Qmax 是控制器学习到的化学容量，不等同于当前可用电量。串联电芯组的 mAh 不相加，不据此给单体打健康分。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.senseiCard()
            }
            if let error = report.systemReportError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }
    }
    private var lifetime: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("控制器保存的寿命统计", systemImage: "chart.bar.xaxis").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("读取控制器已有记录").font(.system(size: 10)).foregroundStyle(SenseiTheme.accent)
            }
            if let range = report.lifetime.temperature {
                HStack {
                    Text("温度范围").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(n(range.average, "平均 %.1f°C")).font(.system(size: 12)).monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [.blue.opacity(0.3), .orange.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                        if let average = range.average, range.upper > range.lower {
                            Circle().fill(Color(nsColor: .textBackgroundColor)).overlay(Circle().stroke(SenseiTheme.accent, lineWidth: 2)).frame(width: 14, height: 14)
                                .offset(x: (geometry.size.width - 14) * (average - range.lower) / (range.upper - range.lower))
                        }
                    }
                }.frame(height: 14).accessibilityHidden(true)
                HStack { Text(n(range.lower, "最低 %.1f°C")); Spacer(); Text(n(range.upper, "最高 %.1f°C")) }
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            } else { Text("历史温度字段未提供，或单位无法交叉验证。").font(.system(size: 12)).foregroundStyle(.secondary) }
            Divider()
            detail("电池组历史电压", report.lifetime.voltage.map { String(format: "%.3f–%.3f V", $0.lower, $0.upper) } ?? "未提供")
            detail("最大充电 / 放电电流", "\(n(report.lifetime.chargePeakAmps, "%.3f A")) / \(n(report.lifetime.dischargePeakAmps, "%.3f A"))")
            if let date = report.lifetime.updated { detail("控制器统计更新时间", date.formatted(date: .abbreviated, time: .shortened)) }
            Text("这些记录由电池控制器维护，可能覆盖安装本 App 之前的使用；极值不代表此刻读数，也不单独用于故障诊断。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.senseiCard()
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12))
    }
}
