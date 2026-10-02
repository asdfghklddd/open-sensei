import Foundation
import AppKit
import IOKit
import Darwin

struct BatteryHealth {
    var cycles: Int?
    var design: Double?
    var full: Double?
    var temperature: Double?
    var voltage: Double?
    var current: Double?
    var inputPower: Double?
    var adapterWatts: Double?
    var adapterVoltage: Double?
    var adapterCurrent: Double?
    var charging: Bool = false
    var pluggedIn: Bool = false
    var failure: Int?
    var remainingCapacity: Double?
    var reportedFullCapacity: Double?
    var designCycles: Int?
    var batteryPower: Double? {
        guard let voltage, let current else { return nil }
        return voltage * current
    }
    var powerLabel: String {
        guard let power = batteryPower else { return "电池功率" }
        return abs(power) < 0.1 ? "电池待机" : (power > 0 ? "电池充入" : "电池放出")
    }
    var capacityPercent: Double? {
        guard let design, let full, design > 0, full > 0 else { return nil }
        let percent = full / design * 100
        return percent.isFinite && (0...120).contains(percent) ? percent : nil
    }
}

enum Hardware {
    static func properties(_ name: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var output: [[String: Any]] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] { output.append(dictionary) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return output
    }
    static func gpu() -> Double? {
        properties("IOAccelerator").compactMap { d -> Double? in
            guard let stats = d["PerformanceStatistics"] as? [String: Any],
                  let value = stats["Device Utilization %"] as? NSNumber else { return nil }
            return min(1, max(0, value.doubleValue / 100))
        }.max()
    }
    static func batteryHealth() -> BatteryHealth {
        guard let data = properties("AppleSmartBattery").first else { return BatteryHealth() }
        return parseBattery(data)
    }
    static func signedCurrent(_ number: NSNumber?) -> Double? {
        guard let number else { return nil }
        let raw = number.int64Value
        let signed: Int64 = raw >= 0 && raw <= Int64(UInt32.max) && raw > Int64(Int32.max) ? Int64(Int32(bitPattern: UInt32(raw))) : raw
        let amps = Double(signed) / 1000
        return abs(amps) <= 30 ? amps : nil
    }
    static func parseBattery(_ d: [String: Any]) -> BatteryHealth {
        let nested = d["BatteryData"] as? [String: Any] ?? [:]
        let adapter = d["AdapterDetails"] as? [String: Any] ?? [:]
        let telemetry = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? { ((d[key] ?? nested[key]) as? NSNumber)?.doubleValue }
        func bounded(_ raw: Double?, _ range: ClosedRange<Double>) -> Double? {
            guard let raw, raw.isFinite, range.contains(raw) else { return nil }; return raw
        }
        let plugged = d["ExternalConnected"] as? Bool ?? false
        let voltage = bounded(number("Voltage").map { $0 / 1000 }, 1...30)
        let av = bounded((adapter["AdapterVoltage"] as? NSNumber).map { $0.doubleValue / 1000 }, 1...60)
        let ac = bounded((adapter["Current"] as? NSNumber).map { $0.doubleValue / 1000 }, 0...15)
        let rated = (adapter["Watts"] as? NSNumber)?.doubleValue ?? av.flatMap { v in ac.map { v * $0 } }
        return BatteryHealth(cycles: number("CycleCount").flatMap { bounded($0, 0...100000).map(Int.init) },
                             design: bounded(number("DesignCapacity"), 1...100000),
                             full: bounded(number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"), 1...100000),
                             temperature: bounded(number("Temperature").map { $0 / 100 }, -10...80), voltage: voltage,
                             current: signedCurrent((d["InstantAmperage"] ?? d["Amperage"]) as? NSNumber),
                             inputPower: plugged ? bounded((telemetry["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1000 }, 0...1000) : nil,
                             adapterWatts: plugged ? bounded(rated, 1...1000) : nil,
                             adapterVoltage: plugged ? av : nil, adapterCurrent: plugged ? ac : nil,
                             charging: d["IsCharging"] as? Bool ?? false, pluggedIn: plugged,
                             failure: number("PermanentFailureStatus").flatMap { bounded($0, 0...Double(Int32.max)).map(Int.init) },
                             remainingCapacity: bounded(number("AppleRawCurrentCapacity") ?? number("RemainingCapacity"), 0...100000),
                             reportedFullCapacity: bounded(number("FullChargeCapacity") ?? number("AppleRawMaxCapacity"), 1...100000),
                             designCycles: number("DesignCycleCount9C").flatMap { bounded($0, 1...10000).map(Int.init) })
    }
    static func memoryPressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "系统未提供" }
        switch level { case 1: return "正常"; case 2: return "偏高"; case 4: return "很高"; default: return "未知" }
    }
    static func swapUsed() -> Double? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return nil }
        return Double(swap.xsu_used)
    }
    static func ownMemory() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) : 0
    }
}

struct DriveInfo: Identifiable {
    var id: String { name }
    let name: String
    let capacity: String
    let smart: String
    let trim: String
}
struct VolumeInfo: Identifiable {
    var id: String { mount }
    let name: String
    let mount: String
    let total: Double?
    let free: Double?
    let format: String
    let connection: String
    let writable: String
}
struct DriveReport {
    let drives: [DriveInfo]
    let volumes: [VolumeInfo]
    let date: Date
}

// Fixed executable and arguments; only explicitly requested, read-only reports use subprocesses.
enum SystemReport {
    static func drives(token: CancellationToken = CancellationToken()) throws -> DriveReport {
        let data = try run("/usr/sbin/system_profiler", ["SPNVMeDataType", "SPSerialATADataType", "SPStorageDataType", "-json", "-detailLevel", "mini"], token: token)
        return try parseDrives(data)
    }
    static func parseDrives(_ data: Data) throws -> DriveReport {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var result: [String: DriveInfo] = [:]
        var volumes: [VolumeInfo] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                if dictionary["smart_status"] != nil || dictionary["spnvme_trim_support"] != nil || dictionary["spsata_trim_support"] != nil {
                    let name = (dictionary["device_name"] ?? dictionary["_name"]) as? String ?? "未命名驱动器"
                    let old = result[name]
                    result[name] = DriveInfo(name: name,
                        capacity: dictionary["size"] as? String ?? old?.capacity ?? "容量见下方卷报告",
                        smart: dictionary["smart_status"] as? String ?? old?.smart ?? "接口未提供",
                        trim: (dictionary["spnvme_trim_support"] ?? dictionary["spsata_trim_support"]) as? String ?? old?.trim ?? "接口未提供")
                }
                if let mount = dictionary["mount_point"] as? String {
                    let drive = dictionary["physical_drive"] as? [String: Any] ?? [:]
                    volumes.append(VolumeInfo(name: dictionary["_name"] as? String ?? "卷", mount: mount,
                        total: (dictionary["size_in_bytes"] as? NSNumber)?.doubleValue,
                        free: (dictionary["free_space_in_bytes"] as? NSNumber)?.doubleValue,
                        format: dictionary["file_system"] as? String ?? "格式未提供",
                        connection: drive["protocol"] as? String ?? "连接类型未提供",
                        writable: dictionary["writable"] as? String ?? "未提供"))
                }
                dictionary.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        // Stable traversal order allows detailed drive fields to complement the volume report.
        for key in ["SPStorageDataType", "SPNVMeDataType", "SPSerialATADataType"] { if let node = root[key] { walk(node) } }
        let uniqueVolumes = Dictionary(volumes.map { ($0.mount, $0) }, uniquingKeysWith: { first, _ in first })
        return DriveReport(drives: result.values.sorted { $0.name < $1.name }, volumes: uniqueVolumes.values.sorted { $0.mount < $1.mount }, date: Date())
    }
    static func run(_ executable: String, _ arguments: [String], token: CancellationToken = CancellationToken()) throws -> Data {
        guard !token.cancelled else { throw ToolError.message("读取已取消") }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handler = token.onCancel { if process.isRunning { process.terminate() } }
        defer { token.removeHandler(handler) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= 2 * 1024 * 1024 else {
                process.terminate()
                throw NSError(domain: "OpenSensei", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统报告超出 2 MB 内存上限，已停止。"])
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard !token.cancelled else { throw ToolError.message("读取已取消") }
        guard process.terminationStatus == 0 else { throw NSError(domain: "OpenSensei", code: 2, userInfo: [NSLocalizedDescriptionKey: "系统报告不可用或超时。可以稍后重试。"] ) }
        return data
    }
}
