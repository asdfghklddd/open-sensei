import Foundation
import SMCCore

struct FanReading: Identifiable {
    let id: Int
    let rpm: Double
    let minimum: Double
    let maximum: Double
    let target: Double?
    let mode: Int?
    var controllable: Bool { minimum >= 0 && maximum > minimum && maximum <= 20_000 && mode != nil }
    var modeLabel: String { mode == 1 ? "手动控制" : (mode == 0 || mode == 3 ? "系统自动" : "模式未知") }
}
struct TemperatureReading: Identifiable {
    let id: String
    let value: Double
    var group: String {
        if id.hasPrefix("TB") || id.hasPrefix("Tb") { return "电池" }
        if id.hasPrefix("Tg") { return "GPU" }
        return "CPU / 核心"
    }
}
struct SensorSnapshot {
    var available = false
    var fans: [FanReading] = []
    var temperatures: [TemperatureReading] = []
    var cells: [Double] = []
    var updated: Date?
    var fanCount: Int?
    var cpuHotspot: Double? { temperatures.filter { $0.group == "CPU / 核心" }.map(\.value).max() }
    var gpuHotspot: Double? { temperatures.filter { $0.group == "GPU" }.map(\.value).max() }
    var hottest: Double? { temperatures.filter { $0.group != "电池" }.map(\.value).max() }
    var batteryTemperature: Double? { temperatures.filter { $0.group == "电池" }.map(\.value).max() }
}

struct SensorDemand: OptionSet {
    let rawValue: Int
    static let core = Self(rawValue: 1)
    static let battery = Self(rawValue: 2)
    static let fans = Self(rawValue: 4)
    static let cells = Self(rawValue: 8)
    static let all: Self = [.core, .battery, .fans, .cells]
}

extension SensorSnapshot {
    mutating func merge(_ next: SensorSnapshot, demand: SensorDemand) {
        if demand.contains(.core) { temperatures.removeAll { $0.group != "电池" } }
        if demand.contains(.battery) { temperatures.removeAll { $0.group == "电池" } }
        temperatures.append(contentsOf: next.temperatures)
        if demand.contains(.fans) { fans = next.fans; fanCount = next.fanCount }
        if demand.contains(.cells) { cells = next.cells }
        available = !temperatures.isEmpty || fanCount != nil || !cells.isEmpty
        updated = next.updated
    }
}

// A connection and its bounded schema cache are owned by Sampler's serial queue.
final class SensorReader {
    private var connection: OpaquePointer?
    private var keys: [String] = []
    private var discovered = false
    private var retryAfter = -Double.infinity
    private var retired = OSSMCStatistics()
    var statistics: OSSMCStatistics {
        let current = os_smc_statistics(connection)
        return OSSMCStatistics(calls: retired.calls + current.calls, metadataHits: retired.metadataHits + current.metadataHits, metadataMisses: retired.metadataMisses + current.metadataMisses)
    }
    deinit { os_smc_close(connection) }
    private func read(_ key: String) -> Double? {
        var value = 0.0
        return os_smc_read(connection, key, &value) == 0 && value.isFinite ? value : nil
    }
    private func close() {
        retired = statistics; os_smc_close(connection); connection = nil; discovered = false; keys = []
    }
    func sample(packVoltage: Double?, demand: SensorDemand = .all) -> SensorSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        guard !demand.isEmpty else { return SensorSnapshot() }
        if connection == nil {
            guard now >= retryAfter else { return SensorSnapshot(updated: Date()) }
            connection = os_smc_open(); retryAfter = now + 60
        }
        guard connection != nil else { return SensorSnapshot(updated: Date()) }
        // Battery-only pages use known battery keys and avoid whole-SMC enumeration.
        if demand.contains(.core), !discovered {
            discovered = true
            if let count = read("#KEY"), count > 0, count < 40_000 {
                for i in 0..<Int(count) where keys.count < 128 {
                    var key = [CChar](repeating: 0, count: 5)
                    guard os_smc_key(connection, UInt32(i), &key) == 0 else { continue }
                    let name = String(cString: key)
                    guard ["Tp", "Tg", "Tc", "TC", "TB", "Tb"].contains(where: name.hasPrefix),
                          let value = read(name), (5...125).contains(value) else { continue }
                    keys.append(name)
                }
            }
            if keys.isEmpty { keys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b", "Tg05", "Tg0D", "Tg0L", "Tg0T", "TB0T", "TB1T", "TB2T"] }
        }
        var result = SensorSnapshot(updated: Date())
        if demand.contains(.fans), let count = read("FNum"), (0...8).contains(count) {
            result.fanCount = Int(count)
            result.fans = (0..<Int(count)).compactMap { index in
                guard let actual = read("F\(index)Ac"), actual >= 0, actual < 20_000 else { return nil }
                return FanReading(id: index, rpm: actual, minimum: read("F\(index)Mn") ?? -1, maximum: read("F\(index)Mx") ?? -1,
                                  target: read("F\(index)Tg"), mode: read("F\(index)Md").map(Int.init))
            }
        }
        let temperatureKeys = discovered ? keys : ["TB0T", "TB1T", "TB2T"]
        result.temperatures = temperatureKeys.compactMap { key in
            let battery = key.hasPrefix("TB") || key.hasPrefix("Tb")
            guard (battery && demand.contains(.battery)) || (!battery && demand.contains(.core)),
                  let value = read(key), (5...125).contains(value) else { return nil }
            return TemperatureReading(id: key, value: value)
        }
        #if arch(arm64)
        if demand.contains(.cells) {
            let cells = (1...8).compactMap { i -> Double? in
                var millivolts = 0.0
                guard os_smc_read_le16(connection, "BC\(i)V", &millivolts) == 0, (2000...5000).contains(millivolts) else { return nil }
                return millivolts / 1000
            }
            result.cells = Self.validatedCells(cells, packVoltage: packVoltage)
        }
        #endif
        result.available = !result.temperatures.isEmpty || result.fanCount != nil || !result.cells.isEmpty
        if !result.available && (demand.contains(.core) || demand.contains(.fans)) { close(); retryAfter = now + 60 }
        return result
    }
    static func validatedCells(_ cells: [Double], packVoltage: Double?) -> [Double] {
        guard let packVoltage, packVoltage.isFinite, !cells.isEmpty, cells.count <= 8,
              cells.allSatisfy({ $0.isFinite && (2...5).contains($0) }),
              abs(cells.reduce(0, +) - packVoltage) < 0.25 else { return [] }
        return cells
    }
}
