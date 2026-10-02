import Foundation

enum FindingLevel: Int { case good, information, attention, unknown }
struct StateFinding: Identifiable {
    let id: String
    let title: String
    let detail: String
    let level: FindingLevel
    let icon: String
}
struct CheckResult {
    let date: Date
    let findings: [StateFinding]
    var attentionCount: Int { findings.filter { $0.level == .attention }.count }
    var summary: String {
        if attentionCount > 0 { return "\(attentionCount) 项值得留意" }
        if findings.contains(where: { $0.level == .unknown }) { return "部分读数未提供，请查看说明" }
        return "当前未发现需要处理的资源压力"
    }
}

enum StateCheck {
    static func make(_ s: Snapshot, now: Date = Date()) -> CheckResult {
        var findings: [StateFinding] = []
        func add(_ id: String, _ title: String, _ detail: String, _ level: FindingLevel, _ icon: String) {
            findings.append(StateFinding(id: id, title: title, detail: detail, level: level, icon: icon))
        }
        func fresh(_ domain: MetricDomain) -> Bool {
            guard let stamp = s.stamps[domain], stamp.condition == .ready else { return false }
            return abs(now.timeIntervalSince(stamp.date)) < (domain == .storage ? 90 : 10)
        }
        if fresh(.memory), let used = s.memoryUsed {
            switch s.memoryPressure {
            case "很高", "偏高":
                add("memory", "内存压力\(s.memoryPressure)", "已用 \(Format.bytes(used))，交换 \(s.swap.map(Format.bytes) ?? "未提供")。可在资源进程页采样，关闭暂时不用的大型应用。", .attention, "memorychip")
            case "正常":
                add("memory", "内存压力正常", "已用 \(Format.bytes(used))，压缩 \(Format.bytes(s.compressed))。macOS 会用空闲内存缓存文件；占用率高或已有交换文件，本身不代表需要清理。", .good, "memorychip")
            default: add("memory", "内存压力未提供", "已用 \(Format.bytes(used))；不能仅凭使用率判断内存是否不足。", .unknown, "memorychip")
            }
        } else { add("memory", "内存读数不足", "系统未返回当前内存压力，稍后可重新检查。", .unknown, "memorychip") }
        if fresh(.cpu), let cpu = s.cpu {
            add("cpu", cpu >= 0.8 ? "CPU 此刻较忙" : "CPU 当前余量充足",
                "本次短采样为 \(Format.percent(cpu))%。\(cpu >= 0.8 ? "可在资源进程页查看哪些应用正在计算。" : "无需为了更低的数字结束系统进程。")短采样不能判定长期负载。", cpu >= 0.8 ? .attention : .good, "cpu")
        } else { add("cpu", "CPU 正在建立基线", "需要两次有效计数才能计算使用率。", .unknown, "cpu") }
        if s.thermal == .serious || s.thermal == .critical {
            add("thermal", "系统正在应对较高热负载", "macOS 报告热压力较高。可暂停大型计算、确认通风；温度与风扇页可查看具体读数。", .attention, "thermometer.high")
        } else {
            add("thermal", s.thermal == .fair ? "系统热压力轻度升高" : "系统热压力正常", "以 macOS 的热压力状态为依据，单个温度读数不用于判定硬件故障。", s.thermal == .fair ? .information : .good, "thermometer.medium")
        }
        if fresh(.storage), let free = s.diskFree, let total = s.diskTotal, total > 0 {
            let low = free < 20_000_000_000 && free / total < 0.1
            add("storage", low ? "可用空间偏少" : "可用空间充足", "用户所在卷可用 \(Format.bytes(free))（\(Format.percent(free / total))%）。\(low ? "可选择文件夹分析大文件，再决定是否移到废纸篓。" : "无需定期清空所有应用缓存。")", low ? .attention : .good, "internaldrive")
        } else { add("storage", "卷容量未提供", "无法取得用户所在卷的当前可用空间。", .unknown, "internaldrive") }
        if fresh(.battery) {
            let h = s.health
            if let failure = h.failure, failure != 0 {
                add("battery", "电池报告了状态标记", "硬件状态码 \(failure)。请在系统电池设置核对维修建议，不根据此代码自行拆卸电池。", .attention, "battery.50percent")
            } else if h.pluggedIn && !h.charging {
                add("battery", "已接电源，电池未充电", "可能已充满、由优化充电暂停，或供电条件尚未满足。单凭此状态不能判定充电器故障；可同时观察实时输入和电池净功率。", .information, "powerplug")
            } else {
                add("battery", h.charging ? "电池正在充电" : "电池正在供电", "电池净功率 \(h.batteryPower.map { String(format: "%+.1f W", $0) } ?? "未提供")。正数表示充入，负数表示放出，不能将充电器额定功率当作电池充入功率。", .information, "bolt")
            }
            if let capacity = h.capacityPercent, capacity < 80 {
                add("capacity", "估算容量已下降", String(format: "满充与设计容量之比为 %.1f%%，这是估算值。可在系统电池设置核对校准后的健康信息。", capacity), .information, "heart")
            }
        } else { add("battery", "内置电池读数未提供", "台式 Mac 可能没有内置电池；有电池的设备也可能暂时未返回数据。", .unknown, "battery.0percent") }
        return CheckResult(date: now, findings: findings)
    }
}

@MainActor final class CheckModel: ObservableObject {
    @Published var result: CheckResult?
    @Published var loading = false
    private var token: CancellationToken?
    func run() {
        guard !loading else { return }
        let token = CancellationToken(); self.token = token; loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sampler = Sampler()
            _ = sampler.sample(domains: [.cpu, .memory, .storage, .battery])
            // This one-shot check has no repeating timer and never opens SMC.
            for _ in 0..<6 { if token.cancelled { return }; Thread.sleep(forTimeInterval: 0.1) }
            let result = StateCheck.make(sampler.sample(domains: [.cpu]))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token === token, !token.cancelled else { return }
                self.result = result; self.loading = false; self.token = nil
            }
        }
    }
    func cancel() { token?.cancel(); token = nil; loading = false }
    func clear() { cancel(); result = nil }
}

struct AppStorageUsage {
    let bundle: Int64
    let preferences: Int64
    let support: Int64
    let caches: Int64
    let partial: Bool
    let date: Date
    var dataBytes: Int64 { preferences + support + caches }
    static func read() -> Self {
        func size(_ url: URL, recursive: Bool = false) -> (Int64, Bool) {
            if !recursive { return (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), false) }
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return (0, false) }
            var total: Int64 = 0, count = 0
            let start = ProcessInfo.processInfo.systemUptime
            for case let file as URL in files {
                count += 1
                if count > 1000 || ProcessInfo.processInfo.systemUptime - start > 1 { return (total, true) }
                guard let value = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
                if value.isSymbolicLink == true { files.skipDescendants(); continue }
                if value.isRegularFile == true { total += Int64(value.fileAllocatedSize ?? 0) }
            }
            return (total, false)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundle = size(Bundle.main.bundleURL, recursive: true)
        let support = size(home.appendingPathComponent("Library/Application Support/OpenSensei"), recursive: true)
        let prefs = size(home.appendingPathComponent("Library/Preferences/local.opensensei.app.plist"))
        let cache = size(home.appendingPathComponent("Library/Caches/local.opensensei.app"), recursive: true)
        let saved = size(home.appendingPathComponent("Library/Saved Application State/local.opensensei.app.savedState"), recursive: true)
        return Self(bundle: bundle.0, preferences: prefs.0, support: support.0, caches: cache.0 + saved.0,
                    partial: bundle.1 || support.1 || cache.1 || saved.1, date: Date())
    }
}
