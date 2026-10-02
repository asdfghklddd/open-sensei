import Foundation
import Darwin
import IOKit.ps

// Every hardware read is made on a serial worker. Measurements stay in RAM.
final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPU: [UInt32]?
    private var previousCPUTime: Double?
    private var previousNetwork: [String: NetworkCounter] = [:]
    private var previousTime: Double?
    private var previousInterface = "all"
    private var cached = Snapshot()
    private let sensors = SensorReader()
    private let diskActivity = DiskActivityReader()
    private var counts: [MetricDomain: Int] = [:]
    private var ownPrevious: (time: Double, cpu: Double)?
    private var iokitBatteryTemperature: Double?

    func resetBaseline() {
        lock.lock(); defer { lock.unlock() }
        previousCPU = nil; previousCPUTime = nil; previousNetwork = [:]; previousTime = nil; ownPrevious = nil; diskActivity.reset()
    }
    static func cpuUsage(old: [UInt32], new: [UInt32]) -> Double? {
        guard old.count == 4, new.count == 4 else { return nil }
        let delta = zip(new, old).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return min(1, max(0, 1 - delta[Int(CPU_STATE_IDLE)] / total))
    }
    func sample(detailed: Bool = true) -> Snapshot { sample(domains: detailed ? MetricDomain.legacy : MetricDomain.basic) }
    func sample(domains: Set<MetricDomain>, interface: String = "all") -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var result = cached
        let start = ProcessInfo.processInfo.systemUptime, date = Date(), smcBefore = sensors.statistics.calls
        result.updated = date
        var work = SamplingWork()
        func mark(_ domain: MetricDomain, _ condition: ReadingCondition = .ready) {
            result.stamps[domain] = ReadingStamp(date: date, condition: condition)
            counts[domain, default: 0] += 1; work.domains.insert(domain)
        }
        if domains.contains(.cpu) || domains.contains(.memory) {
            let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
            if domains.contains(.cpu) {
                var cpu = host_cpu_load_info()
                var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
                let status = withUnsafeMutablePointer(to: &cpu) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) } }
                result.cpu = nil
                if status == KERN_SUCCESS {
                    let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
                    if let previousCPU, let time = previousCPUTime, start - time <= 180 { result.cpu = Self.cpuUsage(old: previousCPU, new: ticks) }
                    previousCPU = ticks; previousCPUTime = start
                }
                mark(.cpu, status != KERN_SUCCESS ? .unavailable : (result.cpu == nil ? .warming : .ready))
            }
            if domains.contains(.memory) {
                var memory = vm_statistics64()
                var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
                let status = withUnsafeMutablePointer(to: &memory) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) } }
                var pageSize: vm_size_t = 0
                result.memoryUsed = nil
                result.appMemory = nil; result.wiredMemory = nil
                if status == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS {
                    let app = max(0, Double(memory.internal_page_count) - Double(memory.purgeable_count))
                    result.memoryUsed = min(result.memoryTotal, (app + Double(memory.wire_count) + Double(memory.compressor_page_count)) * Double(pageSize))
                    result.compressed = Double(memory.compressor_page_count) * Double(pageSize)
                    result.appMemory = app * Double(pageSize)
                    result.wiredMemory = Double(memory.wire_count) * Double(pageSize)
                }
                result.memoryPressure = Hardware.memoryPressure(); result.swap = Hardware.swapUsed()
                mark(.memory, result.memoryUsed == nil ? .unavailable : .ready)
            }
        }
        if domains.contains(.storage), result.stamps[.storage].map({ date.timeIntervalSince($0.date) >= 60 }) ?? true {
            let volume = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            result.diskTotal = values?.volumeTotalCapacity.map(Double.init)
            result.diskFree = values?.volumeAvailableCapacity.map(Double.init)
            mark(.storage, result.diskFree == nil ? .unavailable : .ready)
        }
        if domains.contains(.network) {
            result.network = NetworkRate()
            if let reading = NetworkReader.read() {
                result.interfaces = reading.interfaces
                let selected = NetworkReader.select(reading.counters, interface: interface)
                if selected.isEmpty { previousTime = nil; mark(.network, .unavailable) }
                else {
                    if let previousTime, start - previousTime <= 180, interface == previousInterface,
                       !Set(previousNetwork.keys).isDisjoint(with: Set(selected.keys)) {
                        result.network = NetworkRate.between(previousNetwork, selected, seconds: start - previousTime)
                        mark(.network)
                    } else { mark(.network, .warming) }
                    previousNetwork = selected; previousTime = start; previousInterface = interface
                }
            } else { previousTime = nil; result.interfaces = []; mark(.network, .unavailable) }
        }
        if domains.contains(.activity) {
            result.activity = diskActivity.sample(now: start)
            mark(.activity, result.activity.devices == 0 ? .unavailable : (result.activity.read == nil ? .warming : .ready))
        }
        if domains.contains(.battery) || domains.contains(.cells) {
            result.health = Hardware.batteryHealth(); result.battery = readBattery()
            iokitBatteryTemperature = result.health.temperature
            // Battery and SMC thermometers have different cadences. Keep the
            // last SMC reading until its own refresh, instead of blanking it on
            // every intervening power sample on Macs without the root field.
            result.health.temperature = iokitBatteryTemperature ?? result.sensors.batteryTemperature
            mark(.battery, result.battery == nil && result.health.voltage == nil ? .unavailable : .ready)
        }
        var demand = SensorDemand()
        if domains.contains(.thermal) { demand.formUnion([.core, .battery]) }
        if domains.contains(.batteryTemperature) { demand.insert(.battery) }
        if domains.contains(.fans) { demand.insert(.fans) }
        if domains.contains(.cells) { demand.insert(.cells) }
        if !demand.isEmpty {
            let reading = sensors.sample(packVoltage: result.health.voltage, demand: demand)
            result.sensors.merge(reading, demand: demand)
            if domains.contains(.thermal) { mark(.thermal, reading.hottest == nil ? .unavailable : .ready) }
            if demand.contains(.battery) {
                result.health.temperature = iokitBatteryTemperature ?? reading.batteryTemperature
                mark(.batteryTemperature, result.health.temperature == nil ? .unavailable : .ready)
            }
            if domains.contains(.fans) { mark(.fans, reading.fanCount == nil ? .unavailable : .ready) }
            if domains.contains(.cells) { mark(.cells, reading.cells.isEmpty ? .unavailable : .ready) }
        }
        if domains.contains(.gpu) { result.gpu = Hardware.gpu(); mark(.gpu, result.gpu == nil ? .unavailable : .ready) }
        if domains.contains(.selfUsage) {
            let cpu = Diagnostics.cpuSeconds()
            result.own.cpu = nil
            if let previous = ownPrevious, start > previous.time, start - previous.time <= 180 { result.own.cpu = max(0, (cpu - previous.cpu) / (start - previous.time) * 100) }
            result.own.footprint = Hardware.ownMemory(); ownPrevious = (start, cpu); mark(.selfUsage, result.own.cpu == nil ? .warming : .ready)
        }
        result.thermal = ProcessInfo.processInfo.thermalState
        work.milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        work.smcCalls = sensors.statistics.calls &- smcBefore; work.totals = counts
        result.work = work; cached = result
        return result
    }
    private func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any], data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = data[kIOPSCurrentCapacityKey] as? Int, let maxCapacity = data[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 else { continue }
            let charging = data[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = data[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            let pluggedIn = data[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return Battery(percent: min(1, max(0, Double(current) / Double(maxCapacity))), charging: charging,
                           pluggedIn: pluggedIn, remaining: Battery.validMinutes(minutes, pluggedIn: pluggedIn, charging: charging),
                           condition: data[kIOPSBatteryHealthKey] as? String)
        }
        return nil
    }
}
