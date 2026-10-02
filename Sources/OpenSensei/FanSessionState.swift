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

    mutating func start() {
        guard !busy, !requiresRecovery else { return }
        self = FanSessionState()
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
        case "RESTORED":
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
                error = "未能确认自动模式已恢复。请重启 Mac 恢复固件默认控制；本次不再允许启动手动会话。"
            } else if event.contains("control failed") {
                detail = event.components(separatedBy: " | ").dropFirst().first.map { String($0.prefix(180)) }
                restored = event.contains("; restored")
                requiresRecovery = !restored
                error = restored ? "当前硬件未通过转速设置验证，已确认恢复自动模式。" : "转速设置失败，未确认恢复。请重启 Mac。"
            } else if event.contains("unsupported") {
                error = "控制接口不受支持，或其他软件已在控制风扇。请先在其他风扇软件中恢复自动模式。"
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
