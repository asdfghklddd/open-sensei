import Foundation
import Darwin

struct ProcessRow: Identifiable {
    let id: Int32
    let name: String
    let cpu: Double
    let memory: Double
    var appPath: String? = nil
}
struct ProcessDisplayRow: Identifiable {
    let id: String
    let name: String
    let detail: String
    let cpu: Double
    let memory: Double
}
enum ProcessGrouping {
    static func appPath(_ executable: String) -> String? {
        var parts: [String] = []
        for component in executable.split(separator: "/") {
            parts.append(String(component))
            if component.hasSuffix(".app") { return "/" + parts.joined(separator: "/") }
        }
        return nil
    }
    static func rows(_ rows: [ProcessRow], grouped: Bool) -> [ProcessDisplayRow] {
        guard grouped else { return rows.map { ProcessDisplayRow(id: String($0.id), name: $0.name, detail: "PID \($0.id)", cpu: $0.cpu, memory: $0.memory) } }
        return Dictionary(grouping: rows) { $0.appPath ?? "pid:\($0.id)" }.map { key, values in
            let name = values[0].appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? values[0].name
            return ProcessDisplayRow(id: key, name: name, detail: values.count == 1 ? "PID \(values[0].id)" : "\(values.count) 个进程合计",
                                     cpu: values.reduce(0) { $0 + $1.cpu }, memory: values.reduce(0) { $0 + $1.memory })
        }
    }
}
enum ProcessReader {
    static func cpuPercent(ticks: UInt64, seconds: Double, numerator: UInt32, denominator: UInt32) -> Double {
        guard seconds > 0, denominator > 0 else { return 0 }
        return Double(ticks) * Double(numerator) / Double(denominator) / 1_000_000_000 / seconds * 100
    }
    private struct Counter { let pid: Int32; let name: String; let ticks: UInt64; let memory: UInt64; let started: UInt64; let app: String? }
    private static func counters(token: CancellationToken, paths: Bool) -> [Int32: Counter] {
        let bytes = proc_listallpids(nil, 0)
        guard bytes > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(bytes) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var result: [Int32: Counter] = [:]
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) where pid > 0 {
            if token.cancelled { return [:] }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            var name = [CChar](repeating: 0, count: 1024)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            var app: String?
            if paths {
                var path = [CChar](repeating: 0, count: 4096)
                if proc_pidpath(pid, &path, UInt32(path.count)) > 0 { app = ProcessGrouping.appPath(String(cString: path)) }
            }
            result[pid] = Counter(pid: pid, name: String(cString: name), ticks: info.pti_total_user + info.pti_total_system,
                                  memory: info.pti_resident_size, started: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec, app: app)
        }
        return result
    }
    static func sample(token: CancellationToken = CancellationToken()) -> [ProcessRow] {
        let first = counters(token: token, paths: false)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<6 { if token.cancelled { return [] }; Thread.sleep(forTimeInterval: 0.1) }
        let second = counters(token: token, paths: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return second.values.map { value in
            var cpu = 0.0
            if let old = first[value.pid], old.started == value.started, value.ticks >= old.ticks {
                // proc_taskinfo CPU counters use Mach ticks, not nanoseconds on Apple Silicon.
                cpu = cpuPercent(ticks: value.ticks - old.ticks, seconds: elapsed, numerator: timebase.numer, denominator: timebase.denom)
            }
            return ProcessRow(id: value.pid, name: value.name, cpu: cpu, memory: Double(value.memory), appPath: value.app)
        }
    }
}

@MainActor final class ProcessModel: ObservableObject {
    @Published var rows: [ProcessRow] = []
    @Published var loading = false
    @Published var updated: Date?
    private var token: CancellationToken?
    func refresh() {
        guard !loading else { return }
        let token = CancellationToken(); self.token = token; loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ProcessReader.sample(token: token)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token === token, !token.cancelled else { return }
                self.rows = result; self.loading = false; self.updated = Date(); self.token = nil
            }
        }
    }
    func cancel() { token?.cancel(); token = nil; loading = false }
    func clear() { cancel(); rows = []; updated = nil }
}
