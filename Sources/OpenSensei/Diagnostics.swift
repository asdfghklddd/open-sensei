import Foundation
import Darwin

enum Diagnostics {
    static func run() {
        let sampler = Sampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.35)
        let sample = sampler.sample()
        let data: [String: Any] = ["cpu": sample.cpu ?? -1, "gpu": sample.gpu ?? -1,
                                 "memoryUsed": sample.memoryUsed ?? -1, "memoryPressure": sample.memoryPressure,
                                 "batteryCapacity": sample.health.capacityPercent ?? -1, "batteryCycles": sample.health.cycles ?? -1,
                                 "ownMemoryBytes": Hardware.ownMemory(), "batteryTemperature": sample.health.temperature ?? -1,
                                 "batteryVoltage": sample.health.voltage ?? -1, "batteryAmps": sample.health.current ?? -999,
                                 "batteryWatts": sample.health.batteryPower ?? -999, "inputWatts": sample.health.inputPower ?? -1,
                                 "adapterWatts": sample.health.adapterWatts ?? -1, "cellVolts": sample.sensors.cells,
                                 "hottest": sample.sensors.hottest ?? -1, "sensorCount": sample.sensors.temperatures.count,
                                 "fans": sample.sensors.fans.map { ["id": Double($0.id), "rpm": $0.rpm, "min": $0.minimum, "max": $0.maximum, "mode": Double($0.mode ?? -1)] }]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: json, as: UTF8.self)) }
    }
    @MainActor static func profile() {
        let monitor = Monitor()
        monitor.batteryHistoryEnabled = false
        let visible = CommandLine.arguments.contains("visible")
        monitor.setSurface("profile", visible: visible)
        let startCPU = cpuSeconds()
        let start = ProcessInfo.processInfo.systemUptime
        monitor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let data: [String: Any] = ["mode": visible ? "visible sampler (no UI)" : "idle sampler", "elapsedSeconds": elapsed,
                                     "cpuPercentOneCore": (cpuSeconds() - startCPU) / elapsed * 100,
                                     "memoryFootprintBytes": Hardware.ownMemory(), "samples": monitor.sampleCount,
                                     "retainedTrendPoints": monitor.cpuHistory.count, "historyBytes": monitor.historyBytes]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: json, as: UTF8.self)) }
            exit(0)
        }
        RunLoop.main.run()
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
