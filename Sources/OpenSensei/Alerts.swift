import Foundation
import UserNotifications
import SwiftUI

enum AlertRule: String, CaseIterable, Identifiable {
    case memory, space, battery, batteryTime
    var id: String { rawValue }
    var title: String {
        switch self { case .memory: return "内存压力持续很高"; case .space: return "可用空间持续偏少"; case .battery: return "低电量提醒"; case .batteryTime: return "剩余使用时间提醒" }
    }
    var domain: MetricDomain {
        switch self { case .memory: return .memory; case .space: return .storage; case .battery, .batteryTime: return .battery }
    }
}

// A few timestamps per enabled rule, only in RAM. No alert database or log.
struct AlertGate {
    private struct State { var since: Double?; var lastSeen: Double?; var lastSent: Double? }
    private var states: [AlertRule: State] = [:]
    mutating func evaluate(_ rule: AlertRule, active: Bool?, now: Double, dwell: Double = 60, cooldown: Double = 3600) -> Bool {
        var state = states[rule] ?? State()
        defer { states[rule] = state }
        guard active == true else { state.since = nil; state.lastSeen = now; return false }
        if let last = state.lastSeen, now < last || now - last > 90 { state.since = nil }
        state.lastSeen = now
        if state.since == nil { state.since = now }
        guard now - (state.since ?? now) >= dwell, state.lastSent.map({ now >= $0 && now - $0 >= cooldown }) ?? true else { return false }
        state.lastSent = now; return true
    }
    mutating func remove(_ rule: AlertRule) { states.removeValue(forKey: rule) }
    mutating func resetDwell() {
        for key in Array(states.keys) { states[key]?.since = nil; states[key]?.lastSeen = nil }
    }
    static func condition(_ rule: AlertRule, snapshot s: Snapshot, percentage: Int = 15, minutes: Int = 30) -> Bool? {
        guard s.stamps[rule.domain]?.condition == .ready else { return nil }
        switch rule {
        case .memory: return ["正常", "偏高", "很高"].contains(s.memoryPressure) ? s.memoryPressure == "很高" : nil
        case .space:
            guard let free = s.diskFree, let total = s.diskTotal, total > 0 else { return nil }
            return free < 10_000_000_000 && free / total < 0.05
        case .battery:
            guard let battery = s.battery else { return nil }; return battery.percent < Double(percentage) / 100 && !battery.pluggedIn
        case .batteryTime:
            guard let battery = s.battery else { return nil }
            guard !battery.pluggedIn, !battery.charging else { return false }
            guard let remaining = Battery.validMinutes(battery.remaining, pluggedIn: battery.pluggedIn, charging: battery.charging) else { return nil }
            return remaining < minutes
        }
    }
}

@MainActor final class AlertManager: NSObject, ObservableObject {
    @Published private(set) var enabled: Set<AlertRule>
    @Published private(set) var message: String?
    @Published private(set) var pending = false
    @Published private(set) var batteryPercent = 15
    @Published private(set) var batteryMinutes = 30
    private var gate = AlertGate()
    var onChange: (() -> Void)?
    var domains: Set<MetricDomain> { Set(enabled.map(\.domain)) }
    override init() {
        enabled = Set((UserDefaults.standard.stringArray(forKey: "alertRules") ?? []).compactMap(AlertRule.init(rawValue:)))
        super.init()
        let percent = UserDefaults.standard.integer(forKey: "batteryPercentAlertThreshold")
        let minutes = UserDefaults.standard.integer(forKey: "batteryMinutesAlertThreshold")
        if [5, 10, 15, 20, 30].contains(percent) { batteryPercent = percent }
        if [10, 15, 30, 45, 60].contains(minutes) { batteryMinutes = minutes }
    }
    func setBatteryThreshold(percent: Int? = nil, minutes: Int? = nil) {
        if let percent, [5, 10, 15, 20, 30].contains(percent) {
            batteryPercent = percent; UserDefaults.standard.set(percent, forKey: "batteryPercentAlertThreshold")
        }
        if let minutes, [10, 15, 30, 45, 60].contains(minutes) {
            batteryMinutes = minutes; UserDefaults.standard.set(minutes, forKey: "batteryMinutesAlertThreshold")
        }
        gate.resetDwell()
    }
    func set(_ rule: AlertRule, enabled value: Bool) {
        guard !pending else { return }
        if !value { enabled.remove(rule); gate.remove(rule); save(); return }
        pending = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] allowed, error in
            Task { @MainActor in
                guard let self else { return }; self.pending = false
                if allowed { self.enabled.insert(rule); self.message = nil; self.save() }
                else { self.message = error?.localizedDescription ?? "系统未允许通知，可在 macOS 的通知设置中启用 Open Sensei。" }
            }
        }
    }
    private func save() {
        UserDefaults.standard.set(enabled.map(\.rawValue).sorted(), forKey: "alertRules"); onChange?()
    }
    func resetDwell() { gate.resetDwell() }
    func consume(_ snapshot: Snapshot, now: Double) {
        for rule in enabled where snapshot.work.domains.contains(rule.domain) {
            guard gate.evaluate(rule, active: AlertGate.condition(rule, snapshot: snapshot, percentage: batteryPercent, minutes: batteryMinutes), now: now) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Open Sensei · \(rule.title)"
            switch rule {
            case .memory: content.body = "系统内存压力持续很高。可打开资源进程页检查正在使用内存的应用。"
            case .space: content.body = "可用空间连续低于 10 GB 和卷容量的 5%。可选择文件夹分析大文件。"
            case .battery: content.body = "电量连续至少一分钟低于 \(batteryPercent)%，且未接电源。"
            case .batteryTime: content.body = "系统估算可用时间连续至少一分钟低于 \(batteryMinutes) 分钟，可接入电源。估计会随负载改变。"
            }
            let request = UNNotificationRequest(identifier: "OpenSensei.\(rule.rawValue)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if let error { Task { @MainActor in self?.message = error.localizedDescription } }
            }
        }
    }
}

struct AlertSettingsView: View {
    @ObservedObject var manager: AlertManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AlertRule.allCases) { rule in
                Toggle(rule.title, isOn: Binding(get: { manager.enabled.contains(rule) }, set: { manager.set(rule, enabled: $0) })).disabled(manager.pending)
            }
            HStack(spacing: 24) {
                Picker("低电量阈值", selection: Binding(get: { manager.batteryPercent }, set: { manager.setBatteryThreshold(percent: $0) })) {
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                Picker("剩余时间阈值", selection: Binding(get: { manager.batteryMinutes }, set: { manager.setBatteryThreshold(minutes: $0) })) {
                    ForEach([10, 15, 30, 45, 60], id: \.self) { Text("\($0) 分钟").tag($0) }
                }
            }
            Text("默认关闭。开启后仅为所选规则追加后台采样：通常每 30 秒，卷容量与低电量模式每 60 秒。连续满足至少一分钟才提醒，同一规则一小时内最多一次。只记内存中的时间戳，不保存通知历史。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let message = manager.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
        }
    }
}
