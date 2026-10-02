import Foundation

enum MetricDomain: String, CaseIterable, Codable, Hashable {
    case cpu, memory, network, battery, gpu, thermal, fans, cells, batteryTemperature, storage, activity, selfUsage
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .battery: return "电源"
        case .gpu: return "GPU"
        case .thermal: return "核心温度"
        case .fans: return "风扇"
        case .cells: return "电芯"
        case .batteryTemperature: return "电池温度"
        case .storage: return "卷容量"
        case .activity: return "磁盘活动"
        case .selfUsage: return "本 App"
        }
    }
    static let legacy: Set<Self> = [.cpu, .memory, .network, .battery, .gpu, .thermal, .fans, .cells, .storage]
    static let basic: Set<Self> = [.cpu, .memory, .network, .battery, .storage]
    func foregroundInterval(_ requested: Double) -> Double {
        switch self {
        case .storage: return 60
        case .cells: return max(10, requested)
        case .batteryTemperature: return max(5, requested)
        case .selfUsage: return max(3, requested)
        default: return requested
        }
    }
}

struct SamplingPlan: Equatable {
    var intervals: [MetricDomain: Double] = [:]
    static func make(surfaces: [String: Set<MetricDomain>], menu: String, active: Double, idle: Double,
                     asleep: Bool, lowPower: Bool, history: Bool = false, alerts: Set<MetricDomain> = []) -> Self {
        guard !asleep else { return Self() }
        var result = Self()
        let active = lowPower ? max(5, active) : active
        let idle = lowPower && idle > 0 ? max(60, idle) : idle
        if idle > 0 {
            let domain: MetricDomain? = ["cpu": .cpu, "memory": .memory, "network": .network, "power": .battery, "battery": .battery][menu]
            if let domain { result.intervals[domain] = idle }
        }
        if history { result.intervals[.battery] = min(result.intervals[.battery] ?? 60, 60) }
        for domain in alerts { result.intervals[domain] = min(result.intervals[domain] ?? 60, lowPower || domain == .storage ? 60 : 30) }
        for domain in surfaces.values.reduce(into: Set<MetricDomain>(), { $0.formUnion($1) }) {
            result.intervals[domain] = min(result.intervals[domain] ?? .infinity, domain.foregroundInterval(active))
        }
        // Validating the cell sum requires a contemporaneous pack voltage.
        if let cells = result.intervals[.cells] { result.intervals[.battery] = min(result.intervals[.battery] ?? .infinity, cells) }
        return result
    }
}

// One timer, with separate deadlines. Missed deadlines never cause catch-up bursts.
struct SamplingSchedule {
    private(set) var plan = SamplingPlan()
    private(set) var deadlines: [MetricDomain: Double] = [:]
    mutating func update(_ next: SamplingPlan, now: Double) {
        for domain in Array(deadlines.keys) where next.intervals[domain] == nil { deadlines.removeValue(forKey: domain) }
        for (domain, interval) in next.intervals {
            guard interval.isFinite, interval > 0 else { continue }
            if let previous = plan.intervals[domain], let due = deadlines[domain] {
                // Expanding a view should fetch newly demanded detail promptly.
                deadlines[domain] = interval < previous ? min(due, now) : max(due, now + (interval > previous ? interval : 0))
            } else { deadlines[domain] = now }
        }
        plan = next
    }
    mutating func takeDue(now: Double) -> Set<MetricDomain> {
        var due = Set<MetricDomain>()
        for (domain, deadline) in deadlines where deadline <= now + 0.002 {
            due.insert(domain); deadlines[domain] = now + (plan.intervals[domain] ?? 60)
        }
        return due
    }
    mutating func request(_ domains: Set<MetricDomain>, at time: Double) {
        for domain in domains where plan.intervals[domain] != nil { deadlines[domain] = min(deadlines[domain] ?? time, time) }
    }
    var next: Double? { deadlines.values.min() }
}

enum ReadingCondition: String { case ready, warming, unavailable }
struct ReadingStamp {
    var date: Date
    var condition: ReadingCondition
    func label(now: Date = Date()) -> String {
        switch condition {
        case .warming: return "等待下一次差值"
        case .unavailable: return "接口暂不可用"
        case .ready:
            let seconds = max(0, Int(now.timeIntervalSince(date)))
            if seconds < 5 { return "刚刚更新" }
            if seconds < 60 { return "\(seconds) 秒前" }
            return "\(seconds / 60) 分钟前的读数"
        }
    }
}
struct SamplingWork {
    var milliseconds = 0.0
    var smcCalls: UInt64 = 0
    var domains = Set<MetricDomain>()
    var totals: [MetricDomain: Int] = [:]
}
struct OwnUsage {
    var cpu: Double?
    var footprint: Double = 0
}
