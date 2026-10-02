import Foundation

struct ThermalPoint: Identifiable, Equatable {
    let id: Date
    let cpu: Double?
    let gpu: Double?
    let battery: Double?
}

struct ThermalHistory {
    private(set) var points: [ThermalPoint] = []
    mutating func append(_ sensors: SensorSnapshot) {
        guard let date = sensors.updated, points.last.map({ $0.id < date }) ?? true else { return }
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, (5...125).contains(value) else { return nil }; return value
        }
        let point = ThermalPoint(id: date, cpu: valid(sensors.cpuHotspot), gpu: valid(sensors.gpuHotspot), battery: valid(sensors.batteryTemperature))
        points.append(point)
        if points.count > ResourcePolicy.historyLimit { points.removeFirst(points.count - ResourcePolicy.historyLimit) }
    }
    mutating func clear() { points.removeAll(keepingCapacity: false) }
}

// Deliberately accepts only the monitoring snapshot; never receives process names,
// file paths, network addresses, serial numbers, usernames or authentication data.
enum SnapshotReport {
    static let byteLimit = 8 * 1024
    static func make(_ s: Snapshot, chip: String, cadence: String, version: String) -> String {
        func f(_ value: Double?, _ format: String) -> String {
            guard let value, value.isFinite else { return "未提供" }; return String(format: format, value)
        }
        let date = ISO8601DateFormatter().string(from: s.updated)
        func stamp(_ domain: MetricDomain) -> String {
            guard let value = s.stamps[domain] else { return "尚未采样" }
            return "\(ISO8601DateFormatter().string(from: value.date)) · \(value.label(now: s.updated))"
        }
        var lines = [
            "Open Sensei \(String(version.prefix(32))) · 当前状态摘要", "采样时间：\(date)",
            "芯片：\(String(chip.prefix(100)))", "刷新策略：\(String(cadence.prefix(80)))",
            "CPU：\(f(s.cpu.map { $0 * 100 }, "%.1f%%")) · GPU：\(f(s.gpu.map { $0 * 100 }, "%.1f%%"))",
            "内存：\(f(s.memoryUsed.map { $0 / 1_073_741_824 }, "%.2f GiB")) / \(f(s.memoryTotal / 1_073_741_824, "%.0f GiB")) · 压力：\(s.memoryPressure)",
            "交换：\(f(s.swap.map { $0 / 1_073_741_824 }, "%.2f GiB"))",
            "可用存储：\(f(s.diskFree.map { $0 / 1_000_000_000 }, "%.1f GB"))",
            "下载：\(f(s.stamps[.network]?.condition == .ready ? s.network.download : nil, "%.0f B/s")) · 上传：\(f(s.stamps[.network]?.condition == .ready ? s.network.upload : nil, "%.0f B/s"))",
            "电量：\(f(s.battery.map { $0.percent * 100 }, "%.0f%%")) · \(s.health.charging ? "正在充电" : (s.health.pluggedIn ? "已接电源，未充电" : "电池或未知电源"))",
            "电池：\(f(s.health.voltage, "%.3f V")) · \(f(s.health.current, "%+.3f A")) · \(f(s.health.batteryPower, "%+.2f W"))",
            "供电档位：\(f(s.health.adapterWatts, "%.0f W")) · 实时输入：\(f(s.health.inputPower, "%.2f W"))",
            "估算最大容量：\(f(s.health.capacityPercent, "%.1f%%")) · 循环：\(s.health.cycles.map(String.init) ?? "未提供")",
            "采样时间：温度 \(stamp(.thermal)) · 电芯 \(stamp(.cells))",
            "采样时间：风扇 \(stamp(.fans)) · 电源 \(stamp(.battery))",
            "温度：CPU 传感器最高 \(f(s.sensors.cpuHotspot, "%.1f°C")) · GPU 最高 \(f(s.sensors.gpuHotspot, "%.1f°C")) · 电池 \(f(s.sensors.batteryTemperature, "%.1f°C"))",
            "电芯组电压：" + s.sensors.cells.prefix(8).map { f($0, "%.3f V") }.joined(separator: " / ")
        ]
        for fan in s.sensors.fans.prefix(8) {
            lines.append("风扇 \(fan.id + 1)：\(f(fan.rpm, "%.0f RPM")) · 目标 \(f(fan.target, "%.0f RPM")) · \(fan.modeLabel)")
        }
        lines.append("此摘要只含当前读数，不含序列号、文件路径、进程清单或网络地址；不自动保存、不自动发送。")
        lines.append("容量是估算值；温度 / 电芯电压不能单独判定硬件健康。各模块独立采样，请结合分项时间判断新鲜度。")
        var result = ""
        for line in lines {
            guard (result + line + "\n").utf8.count <= byteLimit else { break }
            result += line + "\n"
        }
        return result
    }
}
