import Foundation

enum ResourcePolicy {
    static let historyLimit = 60
    static let batteryFileLimit = 64 * 1024
    static let batteryDayLimit = 90
    static let scanEntryLimit = 100_000
    static let scanResultLimit = 200
    static let scanSeconds: Double = 25
    static let benchmarkBytes = 32 * 1024 * 1024

    static func interval(visible: Bool, asleep: Bool, lowPower: Bool, active: Double, idle: Double) -> Double? {
        guard !asleep else { return nil }
        if visible { return lowPower ? max(5, active) : active }
        guard idle > 0 else { return nil }
        return lowPower ? max(60, idle) : idle
    }
}

struct BatteryDay: Codable, Equatable {
    let day: String
    let capacity: Double
    let cycles: Int?
}

final class BatteryHistoryStore {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    let url: URL
    private(set) var entries: [BatteryDay] = []
    private(set) var lastError: String?
    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenSensei/battery-daily.json")) {
        self.url = url
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ResourcePolicy.batteryFileLimit,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BatteryDay].self, from: data) else { return }
        entries = Array(decoded.suffix(ResourcePolicy.batteryDayLimit))
    }
    func needsRecord(date: Date = Date()) -> Bool { !entries.contains { $0.day == formatter.string(from: date) } }
    var size: Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0 }
    @discardableResult func record(capacity: Double, cycles: Int?, date: Date = Date()) -> Bool {
        guard capacity.isFinite, (0...120).contains(capacity) else { return false }
        let day = formatter.string(from: date)
        guard !entries.contains(where: { $0.day == day }) else { return false }
        let next = Array((entries + [BatteryDay(day: day, capacity: capacity, cycles: cycles)]).suffix(ResourcePolicy.batteryDayLimit))
        do {
            let data = try JSONEncoder().encode(next)
            guard data.count <= ResourcePolicy.batteryFileLimit else { return false }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            entries = next
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        entries = []
        lastError = nil
    }
}
