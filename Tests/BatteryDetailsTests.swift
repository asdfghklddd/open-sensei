import XCTest
@testable import OpenSensei

final class BatteryDetailsTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1790938000)
    func testMacOS27ChildDataPreservesAggregateAndSkipsIdentifiers() throws {
        let root: [String: Any] = ["DeviceName": "bq40z651", "DesignCycleCount9C": 1000,
            "BatteryData": ["DesignCapacity": 6075, "NominalChargeCapacity": 5398, "FullChargeCapacity": 5248, "RemainingCapacity": 4382]]
        let pack: [String: Any] = ["BatteryData": ["Serial": "PRIVATE", "NominalChargeCapacity": 1, "Temperature": 3329, "PermanentFailureStatus": 0,
            "LifetimeData": ["MinimumTemperature": 10, "MaximumTemperature": 40, "AverageTemperature": 258, "TotalOperatingTime": 19949,
                             "MaximumChargeCurrent": 6551, "MaximumDischargeCurrent": -6186, "MinimumPackVoltage": 8086, "MaximumPackVoltage": 13008]]]
        let report = BatteryDetailsReader.parse(root: root, pack: pack, banks: [
            ["BankID": 2, "BatteryData": ["CellVoltage": 4097, "Qmax": 5841]],
            ["BankID": 0, "BatteryData": ["CellVoltage": 4096, "Qmax": 5850]],
            ["BankID": 0, "BatteryData": ["CellVoltage": 4090, "Qmax": 5000]]], now: date)
        XCTAssertTrue(report.usedPackNode)
        XCTAssertEqual(report.failureCode, 0)
        XCTAssertEqual(report.nominalCapacity, 5398)
        XCTAssertEqual(report.fullCapacity, 5248)
        XCTAssertEqual(report.remainingCapacity, 4382)
        XCTAssertEqual(report.lifetime.temperature, BatteryRange(lower: 10, upper: 40, average: 25.8))
        XCTAssertEqual(report.lifetime.voltage, BatteryRange(lower: 8.086, upper: 13.008))
        XCTAssertEqual(report.lifetime.operatingHours, 19949)
        XCTAssertEqual(report.lifetime.dischargePeakAmps, 6.186)
        XCTAssertEqual(report.banks.map(\.id), [0, 2])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE"))
    }
    func testLifetimeTemperatureUnitsNeedAUniqueConsistentScale() {
        let tenths = BatteryDetailsReader.parseLifetime(["MinimumTemperature": 100, "MaximumTemperature": 400, "AverageTemperature": 258], currentTemperature: 33, now: date)
        XCTAssertEqual(tenths.temperature, BatteryRange(lower: 10, upper: 40, average: 25.8))
        XCTAssertNil(BatteryDetailsReader.parseLifetime(["MinimumTemperature": 0, "MaximumTemperature": 40], currentTemperature: 3, now: date).temperature)
        XCTAssertNil(BatteryDetailsReader.parseLifetime(["MinimumTemperature": 0, "MaximumTemperature": 0], currentTemperature: 33, now: date).temperature)
        XCTAssertNil(BatteryDetailsReader.parseLifetime(["MinimumTemperature": 10, "MaximumTemperature": 40], currentTemperature: nil, now: date).temperature)
        XCTAssertNil(BatteryDetailsReader.parseLifetime(["MaximumChargeCurrent": true], currentTemperature: nil, now: date).chargePeakAmps)
    }
    func testSystemHealthIsSeparateFromNominalRatio() throws {
        var report = BatteryDeepReport(date: date)
        report.nominalCapacity = 5398
        let data = try JSONSerialization.data(withJSONObject: ["SPPowerDataType": [
            ["_name": "spbattery_information", "sppower_battery_health_info": ["sppower_battery_health": "Good", "sppower_battery_health_maximum_capacity": "94%"],
             "sppower_battery_model_info": ["sppower_battery_firmware_version": "0b00", "sppower_battery_serial_number": "PRIVATE"]]
        ]])
        BatteryDetailsReader.mergeSystemReport(data, into: &report)
        XCTAssertEqual(report.systemCapacityPercent, 94)
        XCTAssertEqual(report.nominalCapacity, 5398)
        XCTAssertEqual(report.conditionLabel, "正常")
        XCTAssertEqual(report.firmware, "0b00")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE"))
    }
    func testManufactureMonthRejectsUnknownGaugeInvalidDayAndFuture() {
        let sbs = (2023 - 1980) * 512 + 3 * 32 + 15
        XCTAssertEqual(BatteryDetailsReader.manufactureMonth(sbs, controller: nil, now: date), "2023-03")
        let ascii: UInt64 = 55186860028979
        XCTAssertEqual(BatteryDetailsReader.manufactureMonth(ascii, controller: "bq40z651", now: date), "2026-01")
        XCTAssertNil(BatteryDetailsReader.manufactureMonth(ascii, controller: "unknown", now: date))
        XCTAssertNil(BatteryDetailsReader.manufactureMonth((2023 - 1980) * 512 + 2 * 32 + 30, controller: nil, now: date))
        XCTAssertNil(BatteryDetailsReader.manufactureMonth((2028 - 1980) * 512 + 32 + 1, controller: nil, now: date))
    }
    func testBatteryCapacityNeverTreatsPercentageAsMilliampHours() {
        let reading = Hardware.parseBattery(["MaxCapacity": 100, "CurrentCapacity": 85,
            "BatteryData": ["NominalChargeCapacity": 6150, "DesignCapacity": 6000, "FullChargeCapacity": 5900, "RemainingCapacity": 5100]])
        XCTAssertEqual(reading.capacityPercent ?? 0, 102.5, accuracy: 0.00001)
        XCTAssertEqual(reading.reportedFullCapacity, 5900)
        XCTAssertEqual(reading.remainingCapacity, 5100)
        XCTAssertNil(Hardware.parseBattery(["MaxCapacity": 100, "CurrentCapacity": 85]).remainingCapacity)
    }
    func testRemainingTimeRejectsSentinelsAndACStandby() {
        XCTAssertNil(Battery.validMinutes(65535, pluggedIn: false, charging: false))
        XCTAssertNil(Battery.validMinutes(-1, pluggedIn: false, charging: false))
        XCTAssertNil(Battery.validMinutes(0, pluggedIn: false, charging: false))
        XCTAssertNil(Battery.validMinutes(120, pluggedIn: true, charging: false))
        XCTAssertEqual(Battery.validMinutes(120, pluggedIn: false, charging: false), 120)
        XCTAssertEqual(Battery.validMinutes(60, pluggedIn: true, charging: true), 60)
    }
    func testBatteryMenuRequestsOnlyBatteryInBackground() {
        let plan = SamplingPlan.make(surfaces: [:], menu: "battery", active: 2, idle: 30, asleep: false, lowPower: false)
        XCTAssertEqual(plan.intervals, [.battery: 30])
    }
    func testBatteryAlertsHonorThresholdAndIgnoreUnknownTime() {
        var s = Snapshot()
        s.stamps[.battery] = ReadingStamp(date: date, condition: .ready)
        s.battery = Battery(percent: 0.18, charging: false, pluggedIn: false, remaining: 25)
        XCTAssertEqual(AlertGate.condition(.battery, snapshot: s, percentage: 20), true)
        XCTAssertEqual(AlertGate.condition(.battery, snapshot: s, percentage: 15), false)
        XCTAssertEqual(AlertGate.condition(.batteryTime, snapshot: s, minutes: 30), true)
        s.battery?.remaining = 65535
        XCTAssertNil(AlertGate.condition(.batteryTime, snapshot: s))
        s.battery?.pluggedIn = true
        XCTAssertEqual(AlertGate.condition(.batteryTime, snapshot: s), false)
    }
    func testReadableReportKeepsUnitsUnknownsAndSeparateSourcesWithinBudget() throws {
        var report = BatteryDetailsReader.parse(root: ["Serial": "PRIVATE_SERIAL", "BatteryData": ["NominalChargeCapacity": 5398, "DesignCapacity": 6075]], now: date)
        report.systemCapacityPercent = 94
        report.model = String(repeating: "测", count: 100_000)
        let text = BatteryReportText.make(report, live: Snapshot())
        XCTAssertTrue(text.contains("macOS 最大容量：94%"))
        XCTAssertTrue(text.contains("5398 mAh / 6075 mAh"))
        XCTAssertTrue(text.contains("电池采样于：未提供"))
        XCTAssertFalse(text.contains("PRIVATE_SERIAL"))
        XCTAssertLessThanOrEqual(text.utf8.count, 16_384)
    }
    func testChartScalesDistinguishMissingValuesAndBoundLocalVoltageZoom() throws {
        XCTAssertNil(ChartScale.fraction(nil))
        XCTAssertNil(ChartScale.fraction(.nan))
        XCTAssertNil(ChartScale.fraction(1, total: 0))
        XCTAssertEqual(ChartScale.fraction(0), 0)
        XCTAssertEqual(ChartScale.fraction(102, total: 100), 1)
        let scale = try XCTUnwrap(ChartScale.cellBounds([4.096, 4.097, 4.097]))
        XCTAssertTrue(scale.contains(4.096))
        XCTAssertGreaterThan(scale.upperBound - scale.lowerBound, 0.009)
        XCTAssertNil(ChartScale.cellBounds([]))
        XCTAssertNil(ChartScale.cellBounds([4.09, .infinity]))
    }
}
