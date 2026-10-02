import Foundation
import Darwin

struct BatteryRange: Codable, Equatable {
    let lower: Double
    let upper: Double
    var average: Double?
}

struct BatteryLifetime: Codable, Equatable {
    var temperature: BatteryRange?
    var voltage: BatteryRange?
    var chargePeakAmps: Double?
    var dischargePeakAmps: Double?
    var operatingHours: Double?
    var lastCalibrationCycle: Int?
    var updated: Date?
    var available: Bool {
        temperature != nil || voltage != nil || chargePeakAmps != nil ||
        dischargePeakAmps != nil || operatingHours != nil
    }
}

struct BatteryBank: Identifiable, Codable, Equatable {
    let id: Int
    let volts: Double?
    let learnedCapacity: Double?
}

// Only selected values leave the reader. Raw dictionaries, serials and binary
// controller data are never retained, written to disk or included in reports.
struct BatteryDeepReport: Codable, Equatable {
    let date: Date
    var model: String?
    var controller: String?
    var firmware: String?
    var hardwareRevision: String?
    var condition: String?
    var systemCapacityPercent: Double?
    var manufactureMonth: String?
    var cycles: Int?
    var designCycles: Int?
    var failureCode: Int?
    var designCapacity: Double?
    var nominalCapacity: Double?
    var fullCapacity: Double?
    var remainingCapacity: Double?
    var lifetime = BatteryLifetime()
    var banks: [BatteryBank] = []
    var systemReportError: String?
    var usedPackNode = false

    var conditionLabel: String {
        switch condition {
        case "Good", "Normal": return "正常"
        case "Fair": return "容量有所下降"
        case "Poor", "Check Battery", "Service Recommended": return "建议检查电池"
        case .some: return "系统状态：\(condition ?? "")"
        case .none: return "系统未提供"
        }
    }
}

enum BatteryDetailsReader {
    static func bounded(_ value: Any?, _ range: ClosedRange<Double>) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let value = n.doubleValue
        return value.isFinite && range.contains(value) ? value : nil
    }
    static func shortText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(80))
    }
    static func read(token: CancellationToken = CancellationToken()) throws -> BatteryDeepReport {
        guard !token.cancelled else { throw ToolError.message("读取已取消") }
        let root = Hardware.properties("AppleSmartBattery").first ?? [:]
        // macOS 27 moved pack lifetime and bank learning data to child services.
        // These extra services are read only for this explicit report.
        let packs = Hardware.properties("AppleSmartBatteryPack")
        let pack = packs.count == 1 ? packs[0] : [:]
        let packID = (pack["ID"] as? NSNumber)?.intValue
        let banks = Hardware.properties("AppleSmartBatteryBank").filter {
            guard let packID else { return false }
            return ($0["PackID"] as? NSNumber)?.intValue == packID
        }
        var result = parse(root: root, pack: pack, banks: banks)
        var length = 0
        if sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0, length < 256 {
            var buffer = [CChar](repeating: 0, count: length)
            if sysctlbyname("hw.model", &buffer, &length, nil, 0) == 0 { result.model = String(cString: buffer) }
        }
        do {
            let data = try SystemReport.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json", "-detailLevel", "mini"], token: token)
            mergeSystemReport(data, into: &result)
        } catch {
            guard !token.cancelled else { throw error }
            result.systemReportError = "系统健康报告暂不可用，控制器读数仍可查看。"
        }
        guard !token.cancelled else { throw ToolError.message("读取已取消") }
        return result
    }
    static func parse(root: [String: Any], pack: [String: Any] = [:], banks: [[String: Any]] = [], now: Date = Date()) -> BatteryDeepReport {
        var data = root["BatteryData"] as? [String: Any] ?? [:]
        let packData = pack["BatteryData"] as? [String: Any] ?? [:]
        for (key, value) in packData where data[key] == nil { data[key] = value }
        func value(_ key: String) -> Any? { root[key] ?? data[key] }
        func number(_ key: String, _ range: ClosedRange<Double>) -> Double? { bounded(value(key), range) }
        var result = BatteryDeepReport(date: now)
        result.usedPackNode = !packData.isEmpty
        result.controller = shortText(value("DeviceName"))
        result.designCapacity = number("DesignCapacity", 1...100000)
        result.nominalCapacity = number("NominalChargeCapacity", 1...100000)
        result.fullCapacity = number("FullChargeCapacity", 1...100000) ?? number("AppleRawMaxCapacity", 1...100000)
        result.remainingCapacity = number("AppleRawCurrentCapacity", 0...100000) ?? number("RemainingCapacity", 0...100000)
        result.cycles = number("CycleCount", 0...100000).map(Int.init)
        result.designCycles = number("DesignCycleCount9C", 1...10000).map(Int.init)
        result.failureCode = number("PermanentFailureStatus", 0...Double(Int32.max)).map(Int.init)
        result.manufactureMonth = manufactureMonth(value("ManufactureDate"), controller: result.controller, now: now)
        let life = data["LifetimeData"] as? [String: Any] ?? [:]
        result.lifetime = parseLifetime(life, currentTemperature: number("Temperature", 0...8000).map { $0 / 100 }, now: now)
        var usedIDs = Set<Int>()
        for bank in banks.prefix(8) {
            guard let id = bounded(bank["BankID"], 0...7).map(Int.init), usedIDs.insert(id).inserted else { continue }
            let d = bank["BatteryData"] as? [String: Any] ?? [:]
            result.banks.append(BatteryBank(id: id, volts: bounded(d["CellVoltage"], 2000...5000).map { $0 / 1000 },
                                           learnedCapacity: bounded(d["Qmax"], 1...100000)))
        }
        if result.banks.isEmpty, let volts = data["CellVoltage"] as? [NSNumber], let qmax = data["Qmax"] as? [NSNumber], volts.count == qmax.count {
            result.banks = Array(zip(volts, qmax).prefix(8).enumerated()).map { i, pair in
                BatteryBank(id: i, volts: bounded(pair.0, 2000...5000).map { $0 / 1000 }, learnedCapacity: bounded(pair.1, 1...100000))
            }
        }
        result.banks.sort { $0.id < $1.id }
        return result
    }
    static func parseLifetime(_ d: [String: Any], currentTemperature: Double?, now: Date) -> BatteryLifetime {
        var result = BatteryLifetime()
        // Temperature units vary by controller. Accept a scale only when one
        // plausible candidate contains the contemporaneous pack thermometer.
        if let currentTemperature, currentTemperature.isFinite,
           let min = bounded(d["MinimumTemperature"], -400...1000),
           let max = bounded(d["MaximumTemperature"], -400...1000), max > 0, max >= min {
            let ranges = [1.0, 10.0].map { BatteryRange(lower: min / $0, upper: max / $0) }.filter {
                $0.lower >= -40 && $0.upper <= 100 && $0.lower - 1 <= currentTemperature && currentTemperature <= $0.upper + 1
            }
            if ranges.count == 1 {
                result.temperature = ranges[0]
                if let average = bounded(d["AverageTemperature"], -400...1000) {
                    let values = Set([average, average / 10].filter { $0 >= ranges[0].lower && $0 <= ranges[0].upper })
                    if values.count == 1 { result.temperature?.average = values.first }
                }
            }
        }
        if let lower = bounded(d["MinimumPackVoltage"], 1000...30000),
           let upper = bounded(d["MaximumPackVoltage"], 1000...30000), lower <= upper {
            result.voltage = BatteryRange(lower: lower / 1000, upper: upper / 1000)
        }
        result.chargePeakAmps = bounded(d["MaximumChargeCurrent"], 0...30000).map { $0 / 1000 }
        result.dischargePeakAmps = Hardware.signedCurrent(d["MaximumDischargeCurrent"] as? NSNumber).map(abs)
        result.operatingHours = bounded(d["TotalOperatingTime"], 1...1_000_000)
        result.lastCalibrationCycle = bounded(d["CycleCountLastQmax"], 0...100000).map(Int.init)
        if let seconds = bounded(d["UpdateTime"], 946684800...4102444800), seconds <= now.timeIntervalSince1970 + 300 {
            result.updated = Date(timeIntervalSince1970: seconds)
        }
        return result
    }
    static func manufactureMonth(_ value: Any?, controller: String?, now: Date) -> String? {
        guard let raw = bounded(value, 1...281474976710655).map(UInt64.init) else { return nil }
        let year: Int, month: Int, day: Int
        if raw <= UInt16.max {
            year = 1980 + Int(raw >> 9); month = Int((raw >> 5) & 15); day = Int(raw & 31)
        } else {
            // Known TI gauge encoding. Month precision is deliberate: firmware
            // day interpretation has not been independently verified here.
            guard ["bq40z651", "bq20z451"].contains(controller?.lowercased() ?? "") else { return nil }
            let bytes = (0..<6).map { Int((raw >> ($0 * 8)) & 255) }
            guard bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
            let digits = bytes.map { $0 - 48 }
            year = 1992 + digits[0] * 10 + digits[1]; month = digits[2] * 10 + digits[3]; day = digits[4] * 10 + digits[5]
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard (2000...2091).contains(year), parts.isValidDate(in: calendar),
              let date = calendar.date(from: parts), date <= now else { return nil }
        return String(format: "%04d-%02d", year, month)
    }
    static func mergeSystemReport(_ data: Data, into report: inout BatteryDeepReport) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["SPPowerDataType"] as? [[String: Any]],
              let battery = rows.first(where: { ($0["_name"] as? String) == "spbattery_information" }) else { return }
        let health = battery["sppower_battery_health_info"] as? [String: Any] ?? [:]
        let model = battery["sppower_battery_model_info"] as? [String: Any] ?? [:]
        report.condition = shortText(health["sppower_battery_health"])
        let raw = health["sppower_battery_health_maximum_capacity"]
        let percent = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap { Double($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
        report.systemCapacityPercent = percent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        report.controller = shortText(model["sppower_battery_device_name"]) ?? report.controller
        report.firmware = shortText(model["sppower_battery_firmware_version"])
        report.hardwareRevision = shortText(model["sppower_battery_hardware_revision"])
    }
}

@MainActor final class BatteryDetailsModel: ObservableObject {
    @Published private(set) var report: BatteryDeepReport?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var token: CancellationToken?
    func refresh() {
        guard !loading else { return }
        let next = CancellationToken(); token = next; loading = true; error = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try BatteryDetailsReader.read(token: next) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token === next, !next.cancelled else { return }
                self.loading = false; self.token = nil
                switch result {
                case .success(let report): self.report = report
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func cancel() { token?.cancel(); token = nil; loading = false }
    func clear() { cancel(); report = nil; error = nil }
}
