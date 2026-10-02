import Foundation
import Combine
import Darwin

enum FanControlMode: Int, CaseIterable, Identifiable {
    case fixed = 0, curve = 1
    var id: Int { rawValue }
    var label: String { self == .fixed ? "固定转速" : "温度曲线" }
}

@MainActor final class FanControl: ObservableObject {
    @Published var percentage = 40.0
    @Published var duration = 600
    @Published var mode = FanControlMode.fixed
    @Published private(set) var state = FanSessionState()
    var busy: Bool { state.busy }
    var active: Bool { state.active }
    var status: String { state.status }
    var error: String? { state.error }
    var endsAt: Date? { state.endsAt }
    private var session: FanSession?
    private var heartbeat: Timer?
    private var generation = UUID()
    var onRestore: (() -> Void)?

    func start() {
        guard !busy, !state.requiresRecovery else { return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "FanHelper") else {
            state.receive("ERROR authorization helper missing", duration: duration); return
        }
        let id = UUID(); generation = id
        state.start()
        let worker = FanSession()
        session = worker
        worker.start(helper: helper.path, duration: duration, percent: Int(percentage), mode: mode.rawValue) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.generation == id else { return }
                self.state.receive(event, duration: self.duration)
                if event == "RESTORED" || event.hasPrefix("ERROR control failed; restored") { self.onRestore?() }
                if event == "READY", self.state.phase == .applying {
                    self.session?.ping()
                    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.session?.ping() }
                    }
                    timer.tolerance = 0.2
                    RunLoop.main.add(timer, forMode: .common); self.heartbeat = timer
                }
                if event == "FINISHED" {
                    self.heartbeat?.invalidate(); self.heartbeat = nil; self.session = nil
                }
            }
        }
    }
    func stop() {
        guard busy else { return }
        heartbeat?.invalidate(); heartbeat = nil
        state.stop()
        session?.cancel()
    }
}

// A private AF_UNIX socket is the only transient file. The helper exits on EOF or
// missed heartbeats; no root daemon, password storage, sudoers rule or network listener.
private final class FanSession: @unchecked Sendable {
    private let lock = NSLock()
    private var client: Int32 = -1
    private var listener: Int32 = -1
    private var cancelled = false
    private var everConnected = false
    private var authorizationProcess: Process?
    func ping() {
        lock.lock(); defer { lock.unlock() }
        guard client >= 0, !cancelled else { return }
        var byte: UInt8 = 80
        _ = Darwin.send(client, &byte, 1, 0)
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if !everConnected, let process = authorizationProcess, process.isRunning { process.terminate() }
        if client >= 0 { shutdown(client, SHUT_WR) }
        if listener >= 0 { shutdown(listener, SHUT_RDWR) }
    }
    func start(helper: String, duration: Int, percent: Int, mode: Int, callback: @escaping @Sendable (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let dir = URL(fileURLWithPath: "/private/tmp/OpenSensei-Fan-\(UUID().uuidString)", isDirectory: true)
            let path = dir.appendingPathComponent("session.sock").path
            defer {
                lock.lock(); authorizationProcess = nil; lock.unlock()
                try? FileManager.default.removeItem(at: dir)
                callback("FINISHED")
            }
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { callback("ERROR socket"); return }
            let server = socket(AF_UNIX, SOCK_STREAM, 0)
            guard server >= 0 else { callback("ERROR socket"); return }
            defer { lock.lock(); listener = -1; lock.unlock(); Darwin.close(server) }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { callback("ERROR path"); return }
            withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
                bytes.copyBytes(from: Array(path.utf8) + [0])
            }
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, chmod(path, 0o600) == 0, listen(server, 1) == 0 else { callback("ERROR socket"); return }
            lock.lock(); listener = server; let aborted = cancelled; lock.unlock()
            guard !aborted else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let command = [helper, path, String(getuid()), String(duration), String(percent), String(mode)].map(Self.shellQuote).joined(separator: " ")
            // The system presents the password dialog. Inputs are fixed or validated numbers;
            // two quoting layers prevent paths from becoming AppleScript or shell code.
            let script = "do shell script \(Self.appleString(command)) with administrator privileges with prompt \(Self.appleString("Open Sensei 需要授权临时调节风扇。会话结束后恢复自动模式，不安装常驻服务。"))"
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                if process.terminationStatus != 0 {
                    self.lock.lock()
                    let connected = self.everConnected
                    let cancelled = self.cancelled
                    self.lock.unlock()
                    if !connected && !cancelled { callback("ERROR authorization") }
                    self.cancel()
                }
            }
            lock.lock(); authorizationProcess = process; let cancelledBeforeLaunch = cancelled; lock.unlock()
            guard !cancelledBeforeLaunch else { return }
            do { try process.run() } catch { callback("ERROR authorization"); return }
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            var ready = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                lock.lock(); let stopped = cancelled; lock.unlock()
                if stopped { break }
                var event = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
                let result = poll(&event, 1, 500)
                if result > 0 && event.revents & Int16(POLLIN) != 0 { ready = true; break }
                if result < 0 && errno != EINTR { break }
            }
            lock.lock(); let stoppedBeforeAccept = cancelled; lock.unlock()
            guard ready, !stoppedBeforeAccept else {
                lock.lock(); let timedOut = !cancelled; cancelled = true; lock.unlock()
                if timedOut { callback("ERROR authorization timeout") }
                if process.isRunning { process.terminate() }
                return
            }
            let fd = accept(server, nil, nil)
            guard fd >= 0 else { return }
            defer { lock.lock(); client = -1; lock.unlock(); Darwin.close(fd) }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { callback("ERROR peer"); return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            lock.lock(); client = fd; everConnected = true; let stopped = cancelled; lock.unlock()
            if stopped { shutdown(fd, SHUT_WR) }
            var pending = ""
            while true {
                var bytes = [UInt8](repeating: 0, count: 256)
                let n = recv(fd, &bytes, bytes.count, 0)
                guard n > 0 else { break }
                pending += String(decoding: bytes.prefix(n), as: UTF8.self)
                guard pending.utf8.count <= 1024 else { break }
                while let newline = pending.firstIndex(of: "\n") {
                    callback(String(pending[..<newline])); pending.removeSubrange(...newline)
                }
            }
            withExtendedLifetime(process) {}
        }
    }
    private static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleString(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
