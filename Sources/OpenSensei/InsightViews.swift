import SwiftUI
import AppKit

struct ThermalTrendView: View {
    let history: ThermalHistory
    private let series: [(String, KeyPath<ThermalPoint, Double?>, Color)] = [
        ("CPU / 核心", \.cpu, .orange), ("GPU", \.gpu, .purple), ("电池", \.battery, SenseiTheme.accent)
    ]
    private var bounds: (Double, Double) {
        let values = history.points.flatMap { [$0.cpu, $0.gpu, $0.battery].compactMap { $0 } }
        let low = max(0, floor((values.min() ?? 20) / 10) * 10 - 10)
        let high = min(130, ceil((values.max() ?? 70) / 10) * 10 + 10)
        return (low, max(low + 20, high))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本次温度趋势", systemImage: "chart.xyaxis.line").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(history.points.count) / \(ResourcePolicy.historyLimit) 个点 · 仅内存").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack { Text(String(format: "%.0f°", bounds.1)); Spacer(); Text(String(format: "%.0f°", bounds.0)) }
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 28)
                Canvas { context, size in
                    for y in [0.0, 0.5, 1.0] {
                        var grid = Path(); grid.move(to: CGPoint(x: 0, y: y * size.height)); grid.addLine(to: CGPoint(x: size.width, y: y * size.height))
                        context.stroke(grid, with: .color(.primary.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    }
                    let range = bounds
                    guard let first = history.points.first, let last = history.points.last else { return }
                    let span = max(1, last.id.timeIntervalSince(first.id))
                    for (_, key, color) in series {
                        var path = Path(); var previous: Date?
                        for point in history.points {
                            guard let value = point[keyPath: key] else { previous = nil; continue }
                            let x = point.id.timeIntervalSince(first.id) / span * size.width
                            let y = (1 - (value - range.0) / (range.1 - range.0)) * size.height
                            let position = CGPoint(x: x, y: y)
                            if let date = previous, point.id.timeIntervalSince(date) <= 15 { path.addLine(to: position) }
                            else { path.move(to: position) }
                            context.fill(Path(ellipseIn: CGRect(x: x - 1.7, y: y - 1.7, width: 3.4, height: 3.4)), with: .color(color))
                            previous = point.id
                        }
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    }
                }
                .accessibilityLabel("温度趋势，摄氏度。\(history.points.count) 个采样点。当前数值见图例。")
            }.frame(height: 105)
            HStack(spacing: 20) {
                ForEach(series, id: \.0) { title, key, color in
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(title)
                        Text(history.points.last?[keyPath: key].map { String(format: "%.1f°C", $0) } ?? "—").monospacedDigit()
                    }
                }
                Spacer()
            }.font(.system(size: 11))
            HStack {
                if let first = history.points.first, let last = history.points.last {
                    Text("\(first.id.formatted(date: .omitted, time: .standard)) – \(last.id.formatted(date: .omitted, time: .standard))")
                } else { Text("展开后开始采样") }
                Spacer()
                Text("监测界面全部收起后清空")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.senseiCard()
    }
}

struct SnapshotReportView: View {
    let report: String
    var title = "当前状态摘要"
    var canPrint = false
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("打开时生成的快照 · \(report.utf8.count) 字节 · 不自动保存").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 26)).foregroundStyle(SenseiTheme.accent)
            }
            ScrollView {
                Text(report).font(.system(size: 12, design: .monospaced)).lineSpacing(6)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(canPrint ? "打印面板支持另存为 PDF。" : "仅在点击复制时写入剪贴板。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if canPrint { Button("打印…", action: printReport) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copied ? "已复制" : "复制摘要") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(report, forType: .string)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 650, height: 550).tint(SenseiTheme.accent)
    }

    private func printReport() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = max(200, info.paperSize.width - info.leftMargin - info.rightMargin)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        text.string = report; text.font = .systemFont(ofSize: 11); text.textColor = .black
        text.drawsBackground = false; text.isEditable = false
        text.textContainerInset = NSSize(width: 0, height: 8)
        text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let height = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 100
        text.setFrameSize(NSSize(width: width, height: height + 24))
        let operation = NSPrintOperation(view: text, printInfo: info)
        operation.jobTitle = title
        operation.run()
    }
}
