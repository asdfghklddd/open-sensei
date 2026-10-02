import Foundation

enum BatteryReportText {
    static func make(_ report: BatteryDeepReport, live: Snapshot) -> String {
        func n(_ value: Double?, _ format: String) -> String {
            guard let value, value.isFinite else { return "未提供" }
            return String(format: format, value)
        }
        func text(_ value: String?) -> String {
            guard let value else { return "未提供" }
            return String(value.prefix(80)).components(separatedBy: .controlCharacters).joined(separator: " ")
        }
        let h = live.health, lifetime = report.lifetime
        var lines = [
            "Open Sensei · Mac 电池报告",
            "深度报告读取于：\(report.date.formatted(date: .numeric, time: .standard))",
            "电池采样于：\(live.stamps[.battery]?.date.formatted(date: .numeric, time: .standard) ?? "未提供")",
            "",
            "当前状态",
            "电量：\(n(live.battery.map { $0.percent * 100 }, "%.0f%%"))",
            "供电：\(live.battery == nil ? "未提供" : h.charging ? "正在充电" : h.pluggedIn ? "已接电源，未充电" : "电池供电")",
            "时间估计：\(live.battery?.timeLabel ?? "未提供")",
            "电池温度：\(n(h.temperature, "%.1f °C"))",
            "电压 / 电流：\(n(h.voltage, "%.3f V")) / \(n(h.current, "%+.3f A"))",
            "电池净功率：\(n(h.batteryPower, "%+.1f W"))（正数充入，负数放出）",
            "适配器供电档位 / 实时输入：\(n(h.adapterWatts, "%.0f W")) / \(n(h.inputPower, "%.1f W"))",
            "适配器档位电压 / 电流：\(n(h.adapterVoltage, "%.2f V")) / \(n(h.adapterCurrent, "%.2f A"))",
            "永久故障状态码：\(h.failure.map(String.init) ?? "未提供")（0 不代表完整健康诊断）",
            "",
            "容量与健康（深度报告快照）",
            "macOS 状态：\(text(report.conditionLabel))",
            "macOS 最大容量：\(n(report.systemCapacityPercent, "%.0f%%"))",
            "标称满充 / 设计容量：\(n(report.nominalCapacity, "%.0f mAh")) / \(n(report.designCapacity, "%.0f mAh"))",
            "本次满充估计 / 当前剩余：\(n(report.fullCapacity, "%.0f mAh")) / \(n(report.remainingCapacity, "%.0f mAh"))",
            "循环次数 / 设计参考：\(report.cycles.map(String.init) ?? "未提供") / \(report.designCycles.map(String.init) ?? "未提供")",
            "深度报告永久故障状态码：\(report.failureCode.map(String.init) ?? "未提供")",
            "系统最大容量与标称容量采用不同口径；设计循环数不是寿命倒计时。",
            "",
            "控制器自带的寿命统计",
            "累计工作时间：\(n(lifetime.operatingHours, "%.0f h"))",
            "历史最低 / 最高 / 平均温度：\(n(lifetime.temperature?.lower, "%.1f °C")) / \(n(lifetime.temperature?.upper, "%.1f °C")) / \(n(lifetime.temperature?.average, "%.1f °C"))",
            "历史最低 / 最高电池组电压：\(n(lifetime.voltage?.lower, "%.3f V")) / \(n(lifetime.voltage?.upper, "%.3f V"))",
            "最大充电 / 放电电流：\(n(lifetime.chargePeakAmps, "%.3f A")) / \(n(lifetime.dischargePeakAmps, "%.3f A"))",
            "最近学习容量时的循环：\(lifetime.lastCalibrationCycle.map(String.init) ?? "未提供")",
            "控制器统计更新时间：\(lifetime.updated?.formatted(date: .numeric, time: .standard) ?? "未提供")",
            "寿命统计由电池控制器维护；极值不代表当前读数。",
            "",
            "设备信息",
            "Mac 型号：\(text(report.model))",
            "电池控制器：\(text(report.controller))",
            "制造月份（字段解码推算）：\(text(report.manufactureMonth))",
            "固件 / 硬件版本：\(text(report.firmware)) / \(text(report.hardwareRevision))"
        ]
        if !report.banks.isEmpty {
            lines += ["", "电芯组学习容量（深度报告快照）"]
            for bank in report.banks.prefix(8) {
                lines.append("组 \(bank.id + 1)：\(n(bank.volts, "%.3f V")) · Qmax \(n(bank.learnedCapacity, "%.0f mAh"))")
            }
            lines.append("Qmax 不等同于当前可用容量；串联电芯组 mAh 不相加。")
        }
        lines += ["", "本报告不含设备序列号，不自动存盘。缺失或无法验证的值显示为未提供。"]
        // Defensive byte bound, including when report models are constructed
        // outside the hardware reader. Truncate only at a Unicode boundary.
        let joined = lines.joined(separator: "\n")
        var end = joined.endIndex
        while joined[..<end].utf8.count > 16_384 { end = joined.index(before: end) }
        return String(joined[..<end])
    }
}
