import SwiftUI

enum ChartScale {
    static func fraction(_ value: Double?, total: Double = 1) -> Double? {
        guard let value, value.isFinite, total.isFinite, total > 0, value >= 0 else { return nil }
        return min(1, value / total)
    }
    static func cellBounds(_ values: [Double]) -> ClosedRange<Double>? {
        let valid = values.filter { $0.isFinite && (2...5).contains($0) }
        guard valid.count == values.count, let min = valid.min(), let max = valid.max() else { return nil }
        return (floor((min - 0.005) * 1000) / 1000)...(ceil((max + 0.005) * 1000) / 1000)
    }
}

struct ValueRing: View {
    let fraction: Double?
    let value: String
    let caption: String
    var color = SenseiTheme.accent
    var diameter: CGFloat = 116
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.075), lineWidth: 9)
            if let amount = ChartScale.fraction(fraction) {
                Circle().trim(from: 0, to: amount)
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 3) {
                Text(value).font(.system(size: diameter > 100 ? 28 : 17, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(5).frame(width: diameter, height: diameter)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(caption)，\(value)")
    }
}

struct CapacityComparisonView: View {
    let health: BatteryHealth
    private var rows: [(String, Double?, Color)] {
        [("当前剩余", health.remainingCapacity, SenseiTheme.accent),
         ("本次满充估计", health.reportedFullCapacity, .blue),
         ("标称满充容量", health.full, .purple),
         ("设计容量", health.design, Color.secondary)]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("容量，放在同一刻度看", systemImage: "chart.bar.xaxis").font(.system(size: 14, weight: .semibold))
            let ceiling = max(1, rows.compactMap(\.1).max() ?? 1)
            ForEach(rows, id: \.0) { title, value, color in
                HStack(spacing: 14) {
                    Text(title).frame(width: 96, alignment: .leading).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.045))
                            if let part = ChartScale.fraction(value, total: ceiling) {
                                Capsule().fill(color.opacity(0.75).gradient).frame(width: geometry.size.width * part)
                            }
                        }
                    }.frame(height: 10).accessibilityHidden(true)
                    Text(value.map { String(format: "%.0f mAh", $0) } ?? "未提供").monospacedDigit().frame(width: 84, alignment: .trailing)
                }.font(.system(size: 12)).accessibilityElement(children: .combine)
            }
            Text("标称容量用于估算长期变化；本次满充估计会随温度、负载与控制器学习调整。百分比电量不换算成 mAh。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.senseiCard()
    }
}

struct CellBalanceView: View {
    let values: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("电芯组一致性", systemImage: "circle.grid.1x2").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let low = values.min(), let high = values.max() {
                    Text(String(format: "最大压差 %.0f mV", (high - low) * 1000)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
            }
            if let scale = ChartScale.cellBounds(values) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, value in
                    HStack(spacing: 16) {
                        Text("组 \(i + 1)").foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 2)
                                Circle().fill(SenseiTheme.accent).frame(width: 9, height: 9)
                                    .offset(x: max(0, geometry.size.width - 9) * (value - scale.lowerBound) / (scale.upperBound - scale.lowerBound))
                            }.frame(maxHeight: .infinity)
                        }.frame(height: 17).accessibilityHidden(true)
                        Text(String(format: "%.3f V", value)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }.font(.system(size: 12)).accessibilityElement(children: .combine)
                }
                HStack {
                    Text(String(format: "%.3f V", scale.lowerBound))
                    Spacer()
                    Text("局部放大")
                    Spacer()
                    Text(String(format: "%.3f V", scale.upperBound))
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            } else { Text("当前没有可验证的电芯组电压。").font(.system(size: 12)).foregroundStyle(.secondary) }
            Text("刻度随读数缩放，便于观察细小差异；压差本身不代表电芯健康评分或安全阈值。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.senseiCard()
    }
}

struct MemoryCompositionView: View {
    let snapshot: Snapshot
    private var pieces: [(String, Double, Color)] {
        guard let app = snapshot.appMemory, let wired = snapshot.wiredMemory, let used = snapshot.memoryUsed else { return [] }
        return [("应用", app, SenseiTheme.accent), ("联动", wired, .blue), ("压缩", snapshot.compressed, .purple),
                ("缓存及其余空间", max(0, snapshot.memoryTotal - used), Color.primary.opacity(0.10))]
    }
    var body: some View {
        HStack(spacing: 26) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.06), lineWidth: 13)
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                    let start = pieces.prefix(index).reduce(0) { $0 + $1.1 } / max(1, snapshot.memoryTotal)
                    let end = start + piece.1 / max(1, snapshot.memoryTotal)
                    if end > start {
                        Circle().trim(from: min(1, start + 0.003), to: min(1, max(start + 0.003, end - 0.003)))
                            .stroke(piece.2, style: StrokeStyle(lineWidth: 13, lineCap: .butt)).rotationEffect(.degrees(-90))
                    }
                }
                VStack(spacing: 4) {
                    Text("\(Format.percent(snapshot.memoryUsed == nil ? nil : snapshot.memoryFraction))%")
                        .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("已用内存").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(width: 110, height: 110).padding(8)
                .accessibilityElement(children: .ignore).accessibilityLabel("已用内存，\(Format.percent(snapshot.memoryUsed == nil ? nil : snapshot.memoryFraction))%")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("内存构成", systemImage: "memorychip").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("压力 · \(snapshot.memoryPressure)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(pieces, id: \.0) { title, bytes, color in
                    HStack {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(title).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.bytes(bytes)).monospacedDigit()
                    }.font(.system(size: 12))
                }
                if pieces.isEmpty { Text("等待有效内存读数").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).senseiCard()
    }
}

struct BatteryDailyChart: View, Equatable {
    let days: [BatteryDay]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("每日容量摘要", systemImage: "chart.bar.fill").font(.system(size: 14, weight: .semibold))
            if days.isEmpty {
                ContentUnavailableView("尚无容量摘要", systemImage: "calendar", description: Text("开启后每天最多记录一次。\n保留最多 90 天，不保存实时曲线。")).frame(height: 160)
            } else {
                Canvas { context, size in
                    let width = size.width / CGFloat(max(1, days.count))
                    for (index, day) in days.enumerated() {
                        let fraction = min(1, max(0, day.capacity / 120))
                        let rect = CGRect(x: CGFloat(index) * width + 1, y: size.height * (1 - fraction), width: max(1, min(22, width - 2)), height: size.height * fraction)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(SenseiTheme.accent.opacity(0.75)))
                    }
                    let y = size.height * (1 - 100.0 / 120)
                    var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }.frame(height: 130).accessibilityLabel("每日容量，共 \(days.count) 条；最近 \(days.last?.capacity ?? 0, specifier: "%.1f")%。")
                HStack {
                    Text(days.first?.day ?? ""); Spacer(); Text("虚线 100% · 每柱一个记录日"); Spacer(); Text(days.last?.day ?? "")
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }.frame(maxWidth: .infinity, alignment: .leading).senseiCard()
    }
}
