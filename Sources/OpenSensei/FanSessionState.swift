import Foundation

// The UI never infers a successful restore from a closed connection.
struct FanSessionState {
    enum Phase { case idle, authorizing, applying, running, stopping, finished }
    private(set) var phase = Phase.idle
    private(set) var status = "尚未启动手动会话"
    private(set) var error: String?
    private(set) var detail: String?
    private(set) var endsAt: Date?
    private(set) var restored = false
    private(set) var mayHaveControlled = false
    private(set) var requiresRecovery = false
    var busy: Bool { phase != .idle && phase != .finished }
    var active: Bool { phase == .running }
    var stopLabel: String { mayHaveControlled ? "恢复系统自动" : "取消授权" }

    mutating func start(recovery: Bool = false) {
        guard !busy, !requiresRecovery || recovery else { return }
        let needsRecovery = requiresRecovery
        self = FanSessionState()
        requiresRecovery = needsRecovery
        phase = .authorizing; status = "等待 macOS 管理员授权…"
    }
    mutating func stop() {
        guard busy else { return }
        phase = .stopping
        status = mayHaveControlled ? "正在恢复自动调节…" : "正在取消授权…"
    }
    mutating func receive(_ event: String, duration: Int, now: Date = Date()) {
        switch event {
        case "READY":
            guard phase == .authorizing else { return }
            phase = .applying; mayHaveControlled = true; status = "正在应用转速并验证…"
        case "ACTIVE manual", "ACTIVE thermal", "ACTIVE curve":
            guard phase == .applying || phase == .running else { return }
            if endsAt == nil { endsAt = now.addingTimeInterval(Double(duration)) }
            phase = .running
            status = event.hasSuffix("thermal") ? "温度升高 · 已提高散热转速" : (event.hasSuffix("curve") ? "温度曲线运行中" : "固定转速会话运行中")
        case "RECOVERING":
            phase = .applying; mayHaveControlled = true
            status = "正在验证并恢复系统自动调节…"
        case "RESTORED":
            requiresRecovery = false; error = nil
            restored = true; status = "已确认恢复系统自动调节"
        case "FINISHED":
            guard busy else { return }
            if mayHaveControlled && !restored && error == nil {
                error = "连接已关闭，尚未收到恢复确认。请查看最新风扇模式；若仍为手动或读数不可用，请重启 Mac。"
                requiresRecovery = true
            }
            status = restored ? "已确认恢复系统自动调节" : (error == nil ? "授权已取消" : "会话已结束")
            phase = .finished; endsAt = nil
        default:
            guard event.hasPrefix("ERROR") else { return }
            // A late process-exit callback must not replace the helper's real outcome.
            if event.hasPrefix("ERROR authorization"), phase != .authorizing && phase != .stopping { return }
            if event.contains("restore failed") {
                requiresRecovery = true
                let record = event.components(separatedBy: " | ").dropFirst().joined(separator: " | ")
                if !record.isEmpty { detail = [detail, record].compactMap { $0 }.joined(separator: "\n") }
                let reason = event.contains("stage=4 ") ? "写入自动模式失败" : event.contains("stage=5 ") ? "自动模式回读失败" : event.contains("stage=6 ") ? "等待 1 秒后仍未读到自动模式" : "恢复自动模式未通过验证"
                error = "\(reason)。请停止其他风扇软件的手动控制，再点“重新验证并恢复自动”；仍失败时请重启 Mac。"
            } else if event.contains("control failed") {
                detail = event.components(separatedBy: " | ").dropFirst().first.map { String($0.prefix(180)) }
                restored = event.contains("; restored")
                requiresRecovery = !restored
                let reason = Self.failureReason(event)
                error = restored ? "\(reason)，已确认恢复自动模式。" : "\(reason)，未确认恢复。请重新验证并恢复自动。"
            } else if event.contains("SMC unavailable") {
                error = "无法打开风扇硬件接口或读取风扇数量。请重新验证；持续失败时请重启 Mac。"
            } else if event.contains("unsupported") {
                detail = event.components(separatedBy: " | ").dropFirst().first
                error = "\(Self.failureReason(event))。未开始调速；请检查读数及其他风扇软件后重试。"
            } else if event.contains("authorization timeout") {
                error = "两分钟内未完成系统授权，已取消本次会话；未写入风扇设置。"
            } else if event.contains("authorization cancelled") {
                error = nil; status = "授权已取消"
            } else if event.contains("authorization") {
                error = "系统授权未完成，或控制组件未能启动；未写入风扇设置。请检查 macOS 授权窗口后重试。"
            } else {
                error = "无法建立风扇会话。若已开始调速，组件将在断连或心跳超时后尝试恢复自动模式。"
            }
        }
    }

    private static func failureReason(_ event: String) -> String {
        let reasons = [
            ("reason=mode_read", "无法读取风扇控制模式"),
            ("reason=not_automatic", "风扇当前不是自动模式，可能已有其他控制程序接管"),
            ("reason=minimum_read", "无法读取风扇最低转速"),
            ("reason=maximum_read", "无法读取风扇最高转速"),
            ("reason=invalid_range", "硬件返回的转速范围无效"),
            ("reason=temperature_unavailable", "CPU / GPU 温度读数不可用"),
            ("reason=invalid_curve", "温度曲线计算结果无效"),
            ("reason=mode_changed_or_unreadable", "运行中风扇模式被改变或无法读取"),
            ("stage=1 ", "硬件拒绝手动模式写入"),
            ("stage=2 ", "风扇目标转速写入失败"),
            ("stage=3 ", "设置后回读的模式或目标转速未通过验证")
        ]
        return reasons.first(where: { event.contains($0.0) })?.1 ?? "风扇控制接口未通过验证"
    }

    func title(for sensors: SensorSnapshot) -> String {
        switch phase {
        case .authorizing: return "等待授权"
        case .applying: return "验证转速"
        case .running: return "手动会话"
        case .stopping: return mayHaveControlled ? "正在恢复" : "正在取消"
        case .idle, .finished:
            if requiresRecovery { return "待确认恢复" }
            guard sensors.available, !sensors.fans.isEmpty else { return "暂无读数" }
            if sensors.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) { return "系统自动" }
            if sensors.fans.contains(where: { $0.mode == 1 }) { return "手动模式" }
            return "模式未知"
        }
    }
}
