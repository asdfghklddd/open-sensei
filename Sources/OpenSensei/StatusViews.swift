import SwiftUI

enum AppVersion {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.2" }
}

struct FreshnessLabel: View {
    let snapshot: Snapshot
    let domain: MetricDomain
    var body: some View {
        let stamp = snapshot.stamps[domain]
        Label(stamp?.label(now: snapshot.updated) ?? "尚未采样", systemImage: stamp?.condition == .unavailable ? "questionmark.circle" : "clock")
            .font(.system(size: 10)).foregroundStyle(stamp?.condition == .unavailable ? Color.orange : SenseiTheme.secondary)
            .help("\(domain.label) · \(stamp?.date.formatted(date: .omitted, time: .standard) ?? "尚未采样")")
    }
}

struct CheckView: View {
    @ObservedObject var model: CheckModel
    var openPage: (CenterPage) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.result?.summary ?? "一次短检查，看清当前状态")
                        .font(.system(size: 18, weight: .medium))
                    if let date = model.result?.date { Text("检查于 \(date.formatted(date: .omitted, time: .standard))").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small); Button("取消") { model.cancel() } }
                Button(model.result == nil ? "开始检查" : "重新检查") { model.run() }.disabled(model.loading).buttonStyle(.borderedProminent)
            }.senseiCard()
            Text("约一秒完成，只读取 CPU、内存、卷容量和电源状态。结果留在本窗口，不持续扫描、不自动保存。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let result = model.result {
                ForEach(result.findings) { finding in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: finding.icon).font(.system(size: 19)).frame(width: 25).foregroundStyle(color(finding.level))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(finding.title).font(.system(size: 14, weight: .medium))
                            Text(finding.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).senseiCard()
                }
            }
            HStack {
                Button("资源进程") { openPage(.processes) }
                Button("空间整理") { openPage(.storage) }
                Button("电池详情") { openPage(.hardware) }
            }.controlSize(.small)
        }
    }
    private func color(_ level: FindingLevel) -> Color {
        switch level { case .good: return SenseiTheme.accent; case .attention: return .orange; default: return .secondary }
    }
}

struct ActivityView: View {
    @ObservedObject var monitor: Monitor
    private var s: Snapshot { monitor.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label("网络活动", systemImage: "network").font(.system(size: 14, weight: .semibold))
                    Spacer(); FreshnessLabel(snapshot: s, domain: .network)
                }
                Picker("统计接口", selection: Binding(get: { monitor.networkInterface }, set: { monitor.setNetworkInterface($0) })) {
                    Text("en* 接口合计 · 不叠加 VPN").tag("all")
                    ForEach(s.interfaces) { item in Text(item.label).tag(item.name) }
                    if monitor.networkInterface != "all", !s.interfaces.contains(where: { $0.name == monitor.networkInterface }) {
                        Text("\(monitor.networkInterface) · 当前不可用").tag(monitor.networkInterface)
                    }
                }
                HStack(spacing: 12) {
                    ReadingTile(title: "下载", value: s.stamps[.network]?.condition == .ready ? Format.rate(s.network.download) : "—", detail: "当前接口的接收速率", icon: "arrow.down")
                    ReadingTile(title: "上传", value: s.stamps[.network]?.condition == .ready ? Format.rate(s.network.upload) : "—", detail: "当前接口的发送速率", icon: "arrow.up", color: .purple)
                }
                HStack(spacing: 20) {
                    Sparkline(values: monitor.downloadHistory, color: SenseiTheme.accent, ceiling: max(1024, monitor.downloadHistory.max() ?? 0))
                    Sparkline(values: monitor.uploadHistory, color: .purple, ceiling: max(1024, monitor.uploadHistory.max() ?? 0))
                }.frame(height: 40)
                Text("网络计数包含所选接口的实际流量，可能包含局域网通信。VPN 隧道单独查看，避免与底层接口重复合计；接口已启用不等于互联网一定可达。切换接口后重新建立速率基线。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.senseiCard()
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label("磁盘活动", systemImage: "internaldrive").font(.system(size: 14, weight: .semibold))
                    Spacer(); FreshnessLabel(snapshot: s, domain: .activity)
                }
                HStack(spacing: 12) {
                    ReadingTile(title: "读取", value: s.activity.read.map(Format.rate) ?? "—", detail: "存储驱动的读取计数差值", icon: "arrow.up.doc", color: .orange)
                    ReadingTile(title: "写入", value: s.activity.write.map(Format.rate) ?? "—", detail: "存储驱动的写入计数差值", icon: "arrow.down.doc", color: .orange)
                }
                Text("已取得 \(s.activity.devices) 个存储驱动的计数，包含驱动可见的设备；不代表某个应用或 APFS 卷的独立速度，也不是磁盘测速。关闭此页即停止磁盘活动采样。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.senseiCard()
        }
    }
}

struct EfficiencyView: View {
    @ObservedObject var monitor: Monitor
    @State private var usage: AppStorageUsage?
    @State private var readingStorage = false
    private var s: Snapshot { monitor.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ReadingTile(title: "本 App 的 CPU", value: s.own.cpu.map { String(format: "%.2f%%", $0) } ?? "—", detail: "单核心 100% · 本页每 3 秒更新", icon: "cpu")
                ReadingTile(title: "本 App 的内存", value: s.own.footprint > 0 ? Format.bytes(s.own.footprint) : "—", detail: "系统报告的物理内存占用", icon: "memorychip")
            }
            VStack(alignment: .leading, spacing: 13) {
                HStack { Label("此刻正在读取什么", systemImage: "leaf").font(.system(size: 14, weight: .semibold)); Spacer(); Text(monitor.cadenceLabel).font(.system(size: 11)).foregroundStyle(SenseiTheme.accent) }
                ForEach(MetricDomain.allCases, id: \.self) { domain in
                    HStack {
                        Circle().fill(monitor.currentPlan.intervals[domain] == nil ? Color.secondary.opacity(0.3) : SenseiTheme.accent).frame(width: 6, height: 6)
                        Text(domain.label).frame(width: 90, alignment: .leading)
                        Text(monitor.currentPlan.intervals[domain].map { "每 \(Int($0)) 秒" } ?? "未请求")
                        Spacer()
                        Text("本次运行 \(s.work.totals[domain] ?? 0) 次").monospacedDigit().foregroundStyle(.secondary)
                    }.font(.system(size: 12))
                }
                Divider()
                Text(String(format: "最近一次采集 %.2f ms · SMC 调用 %llu 次 · 趋势最多 %d 点 / 序列", s.work.milliseconds, s.work.smcCalls, ResourcePolicy.historyLimit))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text("其他打开的窗口和菜单栏也会请求数据，重复请求合并采集。本页自身也有渲染开销，不能用这里的 CPU 数字代替收起后的后台测试。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.senseiCard()
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("磁盘占用", systemImage: "externaldrive").font(.system(size: 14, weight: .semibold))
                    Spacer(); Button(readingStorage ? "读取中…" : "刷新占用") { refreshStorage() }.disabled(readingStorage).controlSize(.small)
                }
                if let usage {
                    usageRow("App 本体", bytes: usage.bundle)
                    usageRow("偏好设置", bytes: usage.preferences)
                    usageRow("应用支持文件（含可选电池摘要）", bytes: usage.support)
                    usageRow("本 App 的缓存与窗口状态", bytes: usage.caches)
                    Text("\(usage.date.formatted(date: .omitted, time: .shortened)) 读取\(usage.partial ? " · 已达预算，数值为部分结果" : "")。偏好设置由 macOS 异步落盘；App 本体按分配空间统计。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("监测趋势仅存在于内存，默认不保存日志和历史数据库。电池每日摘要默认关闭，开启后最多 90 条、64 KiB。扫描、进程清单与状态检查不落盘。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.senseiCard()
        }.task { refreshStorage() }
    }
    private func usageRow(_ name: String, bytes: Int64) -> some View {
        HStack { Text(name); Spacer(); Text(Format.bytes(Double(bytes))).monospacedDigit() }.font(.system(size: 12))
    }
    private func refreshStorage() {
        guard !readingStorage else { return }; readingStorage = true
        Task { usage = await Task.detached(priority: .utility) { AppStorageUsage.read() }.value; readingStorage = false }
    }
}
