import Foundation
import Combine
import Darwin
import IOKit.ps

struct NetworkCounter {
    var received: UInt64
    var sent: UInt64
}

struct NetworkRate {
    var download: Double = 0
    var upload: Double = 0

    static func between(_ old: [String: NetworkCounter], _ new: [String: NetworkCounter], seconds: Double) -> NetworkRate {
        guard seconds > 0 else { return NetworkRate() }
        var result = NetworkRate()
        for (name, current) in new {
            guard let previous = old[name] else { continue }
            if current.received >= previous.received {
                result.download += Double(current.received - previous.received) / seconds
            }
            if current.sent >= previous.sent {
                result.upload += Double(current.sent - previous.sent) / seconds
            }
        }
        return result
    }
}

struct Battery {
    var percent: Double
    var charging: Bool
    var pluggedIn: Bool
    var remaining: Int?
    var condition: String? = nil
    static func validMinutes(_ value: Int?, pluggedIn: Bool, charging: Bool) -> Int? {
        guard !pluggedIn || charging, let value, (1...10080).contains(value) else { return nil }
        return value
    }
    var timeLabel: String {
        guard let remaining else { return pluggedIn && !charging ? "当前无需倒计时" : "系统正在估算" }
        let hours = remaining / 60, minutes = remaining % 60
        let duration = hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
        return (charging ? "预计充满 " : "预计可用 ") + duration
    }
}

struct Snapshot {
    var cpu: Double?
    var memoryUsed: Double?
    var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var compressed: Double = 0
    var appMemory: Double?
    var wiredMemory: Double?
    var diskFree: Double?
    var diskTotal: Double?
    var network = NetworkRate()
    var interfaces: [NetworkInterface] = []
    var activity = DiskActivity()
    var battery: Battery?
    var thermal = ProcessInfo.ThermalState.nominal
    var updated = Date()
    var stamps: [MetricDomain: ReadingStamp] = [:]
    var work = SamplingWork()
    var own = OwnUsage()
    var gpu: Double?
    var health = BatteryHealth()
    var sensors = SensorSnapshot()
    var memoryPressure = "等待采样"
    var swap: Double?
    var memoryFraction: Double { min(1, max(0, (memoryUsed ?? 0) / max(1, memoryTotal))) }
    var diskFraction: Double { min(1, max(0, 1 - (diskFree ?? 0) / max(1, diskTotal ?? 1))) }
}

enum Format {
    static func bytes(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value <= 0 { return "0 B" }
        guard value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
    static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value < 1_000 { return String(format: "%.0f B/s", value) }
        if value < 1_000_000 { return String(format: "%.1f KB/s", value / 1_000) }
        return String(format: "%.1f MB/s", value / 1_000_000)
    }
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f", value * 100)
    }
}

@MainActor final class Monitor: ObservableObject {
    @Published var snapshot = Snapshot()
    // Snapshot is published once after a complete round; history changes share that update.
    private(set) var cpuHistory: [Double] = []
    private(set) var thermalHistory = ThermalHistory()
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []
    @Published var pinned = false
    @Published var panelCollapsed = false
    @Published var dashboardOrder: [DashboardModule]
    @Published var interval: Double
    @Published var idleInterval: Double
    @Published var visible = false
    @Published var asleep = false
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var thermalPressure = ProcessInfo.processInfo.thermalState
    @Published var batteryHistoryEnabled: Bool
    @Published var showGPU: Bool
    @Published var showNetwork: Bool
    @Published var showBattery: Bool
    @Published var showTemperatures: Bool
    @Published var menuMetric: String
    @Published var networkInterface: String
    @Published var historyBytes = 0
    @Published var historyDays: [BatteryDay] = []
    @Published var historyError: String?
    private(set) var sampleCount = 0
    private(set) var historyStart: Date?
    private enum Surface: Equatable { case dashboard, fixed(Set<MetricDomain>) }
    private var surfaces: [String: Surface] = [:]
    private var generation = 0
    private var started = false
    let alerts = AlertManager()
    let historyStore: BatteryHistoryStore
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "local.opensensei.sampling", qos: .utility)
    private var timer: Timer?
    private var sampling = false
    private var schedule = SamplingSchedule()
    private var powerSource: CFRunLoopSource?
    var onUpdate: (() -> Void)?
    let chip: String

    init(historyStore: BatteryHistoryStore = BatteryHistoryStore()) {
        dashboardOrder = DashboardModule.normalized(UserDefaults.standard.stringArray(forKey: "dashboardOrder") ?? [])
        self.historyStore = historyStore; historyBytes = historyStore.size; historyDays = historyStore.entries
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        interval = [1.0, 2.0, 5.0].contains(saved) ? saved : 2
        let idle = UserDefaults.standard.object(forKey: "idleInterval") as? Double ?? 30
        idleInterval = [0.0, 30.0, 60.0, 120.0].contains(idle) ? idle : 30
        batteryHistoryEnabled = UserDefaults.standard.bool(forKey: "batteryHistoryEnabled")
        showGPU = UserDefaults.standard.object(forKey: "showGPU") as? Bool ?? true
        showNetwork = UserDefaults.standard.object(forKey: "showNetwork") as? Bool ?? true
        showBattery = UserDefaults.standard.object(forKey: "showBattery") as? Bool ?? true
        showTemperatures = UserDefaults.standard.object(forKey: "showTemperatures") as? Bool ?? true
        menuMetric = UserDefaults.standard.string(forKey: "menuMetric") ?? "cpu"
        networkInterface = UserDefaults.standard.string(forKey: "networkInterface") ?? "all"
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        chip = sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 ? String(cString: bytes) : "Mac"
    }
    deinit {
        timer?.invalidate()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    }
    func start() {
        guard !started else { return }; started = true
        alerts.onChange = { [weak self] in self?.reschedule() }
        powerSource = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let monitor = Unmanaged<Monitor>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { monitor.requestRefresh([.battery]) }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        reschedule()
    }
    var dashboardDomains: Set<MetricDomain> {
        var domains: Set<MetricDomain> = [.cpu, .memory, .storage]
        if showGPU { domains.insert(.gpu) }
        if showNetwork { domains.insert(.network) }
        if showBattery { domains.formUnion([.battery, .batteryTemperature]) }
        if showTemperatures { domains.insert(.thermal) }
        return domains
    }
    var currentPlan: SamplingPlan {
        let requests = surfaces.mapValues { surface -> Set<MetricDomain> in
            switch surface { case .dashboard: return dashboardDomains; case .fixed(let domains): return domains }
        }
        return SamplingPlan.make(surfaces: requests, menu: menuMetric, active: interval, idle: idleInterval,
                                 asleep: asleep, lowPower: lowPower || thermalPressure == .serious || thermalPressure == .critical,
                                 history: batteryHistoryEnabled && historyStore.needsRecord(), alerts: alerts.domains)
    }
    var effectiveInterval: Double? { currentPlan.intervals.values.min() }
    var cadenceLabel: String {
        guard let seconds = effectiveInterval else { return asleep ? "休眠 · 暂停采样" : "按需待机" }
        return "\(visible ? "展开" : "后台") · 最快 \(Int(seconds)) 秒"
    }
    var menuTitle: String {
        switch menuMetric {
        case "memory": return " \(Format.percent(snapshot.memoryUsed == nil ? nil : snapshot.memoryFraction))%"
        case "network": return snapshot.stamps[.network]?.condition == .ready ? " ↓ " + Format.rate(snapshot.network.download) : " ↓ —"
        case "power": return snapshot.health.inputPower.map { String(format: " %.1f W", $0) } ?? " — W"
        case "battery": return snapshot.battery.map { " \(Format.percent($0.percent))%" } ?? " —%"
        case "icon": return ""
        default: return " \(Format.percent(snapshot.cpu))%"
        }
    }
    func setSurface(_ name: String, visible isVisible: Bool, domains: Set<MetricDomain>? = nil) {
        let next: Surface? = isVisible ? (domains.map(Surface.fixed) ?? (name == "profile" ? .fixed(MetricDomain.legacy) : .dashboard)) : nil
        guard surfaces[name] != next else { return }
        surfaces[name] = next
        let nextVisible = !surfaces.isEmpty
        if visible != nextVisible { visible = nextVisible; clearTrends() }
        reschedule()
    }
    func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value; generation += 1; clearTrends(); alerts.resetDwell()
        queue.async { [sampler] in sampler.resetBaseline() }
        reschedule()
    }
    func dayChanged() { reschedule() }
    func updatePowerState() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled; thermalPressure = ProcessInfo.processInfo.thermalState; reschedule()
    }
    private func clearTrends() {
        cpuHistory = []; downloadHistory = []; uploadHistory = []; thermalHistory.clear(); historyStart = nil
    }
    private func reschedule() {
        schedule.update(currentPlan, now: ProcessInfo.processInfo.systemUptime)
        guard started else { return }; armTimer()
    }
    private func armTimer() {
        timer?.invalidate(); timer = nil
        guard started, !sampling, let due = schedule.next else { return }
        let wait = max(0, due - ProcessInfo.processInfo.systemUptime)
        if wait <= 0.002 { refresh(); return }
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = visible ? min(0.2, wait * 0.1) : min(5, wait * 0.15)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func requestRefresh(_ domains: Set<MetricDomain>? = nil) {
        guard !asleep else { return }
        schedule.request(domains ?? Set(currentPlan.intervals.keys), at: ProcessInfo.processInfo.systemUptime)
        armTimer()
    }
    func setInterval(_ value: Double) {
        guard [1.0, 2.0, 5.0].contains(value), value != interval else { return }
        interval = value; UserDefaults.standard.set(value, forKey: "refreshInterval"); reschedule()
    }
    func setIdleInterval(_ value: Double) {
        guard [0.0, 30.0, 60.0, 120.0].contains(value), value != idleInterval else { return }
        idleInterval = value; UserDefaults.standard.set(value, forKey: "idleInterval"); reschedule()
    }
    func moveModule(_ module: DashboardModule, by offset: Int) {
        guard let index = dashboardOrder.firstIndex(of: module), dashboardOrder.indices.contains(index + offset) else { return }
        dashboardOrder.swapAt(index, index + offset)
        UserDefaults.standard.set(dashboardOrder.map(\.rawValue), forKey: "dashboardOrder")
    }
    func setNetworkInterface(_ name: String) {
        guard name != networkInterface else { return }
        // Discard a queued result for the previous interface before it can be displayed.
        generation += 1
        networkInterface = name; downloadHistory = []; uploadHistory = []
        var next = snapshot
        next.network = NetworkRate(); next.stamps[.network] = ReadingStamp(date: Date(), condition: .warming)
        snapshot = next
        saveAppearance(); requestRefresh([.network])
    }
    func saveAppearance() {
        UserDefaults.standard.set(showGPU, forKey: "showGPU")
        UserDefaults.standard.set(showNetwork, forKey: "showNetwork")
        UserDefaults.standard.set(showBattery, forKey: "showBattery")
        UserDefaults.standard.set(showTemperatures, forKey: "showTemperatures")
        UserDefaults.standard.set(menuMetric, forKey: "menuMetric")
        UserDefaults.standard.set(networkInterface, forKey: "networkInterface")
        reschedule(); onUpdate?()
    }
    func setBatteryHistory(_ enabled: Bool) {
        batteryHistoryEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "batteryHistoryEnabled")
        if enabled { recordBatteryDay() }; reschedule()
    }
    func clearHistory() {
        do { try historyStore.clear(); historyDays = []; historyBytes = 0; historyError = nil }
        catch { historyError = error.localizedDescription }
    }
    private func recordBatteryDay() {
        guard batteryHistoryEnabled, let stamp = snapshot.stamps[.battery], stamp.condition == .ready, abs(Date().timeIntervalSince(stamp.date)) < 120, let capacity = snapshot.health.capacityPercent else { return }
        if historyStore.record(capacity: capacity, cycles: snapshot.health.cycles) {
            historyDays = historyStore.entries; historyBytes = historyStore.size; reschedule()
        }
        historyError = historyStore.lastError
    }
    private func refresh() {
        guard !sampling, !asleep else { return }
        let domains = schedule.takeDue(now: ProcessInfo.processInfo.systemUptime)
        guard !domains.isEmpty else { armTimer(); return }
        sampling = true
        let current = generation, interface = networkInterface
        queue.async { [self, sampler = self.sampler] in
            let sample = sampler.sample(domains: domains, interface: interface)
            DispatchQueue.main.async { [self] in
                sampling = false
                guard current == generation, !asleep else { armTimer(); return }
                sampleCount += 1
                if visible {
                    let wanted = surfaces.values.reduce(into: Set<MetricDomain>()) { result, surface in
                        switch surface { case .dashboard: result.formUnion(dashboardDomains); case .fixed(let list): result.formUnion(list) }
                    }
                    if domains.contains(.thermal), wanted.contains(.thermal) { thermalHistory.append(sample.sensors) }
                    if domains.contains(.cpu), wanted.contains(.cpu), let cpu = sample.cpu {
                        cpuHistory = Array((cpuHistory + [cpu]).suffix(ResourcePolicy.historyLimit))
                        if historyStart == nil { historyStart = sample.updated }
                    }
                    if domains.contains(.network), wanted.contains(.network), sample.stamps[.network]?.condition == .ready {
                        downloadHistory = Array((downloadHistory + [sample.network.download]).suffix(ResourcePolicy.historyLimit))
                        uploadHistory = Array((uploadHistory + [sample.network.upload]).suffix(ResourcePolicy.historyLimit))
                    }
                    let warming = Set(domains.intersection([.cpu, .network, .activity]).filter { sample.stamps[$0]?.condition == .warming })
                    schedule.request(warming, at: ProcessInfo.processInfo.systemUptime + 0.35)
                }
                snapshot = sample
                alerts.consume(sample, now: ProcessInfo.processInfo.systemUptime)
                if domains.contains(.battery) { recordBatteryDay() }
                onUpdate?(); armTimer()
            }
        }
    }
}
