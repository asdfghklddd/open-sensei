import XCTest
@testable import OpenSensei

final class HardwareTests: XCTestCase {
    func testSignedBatteryCurrentHandlesUnsignedDriverRepresentations() {
        XCTAssertEqual(Hardware.signedCurrent(NSNumber(value: Int64(-1200))), -1.2)
        XCTAssertEqual(Hardware.signedCurrent(NSNumber(value: UInt64.max - 1199)), -1.2)
        XCTAssertEqual(Hardware.signedCurrent(NSNumber(value: UInt32.max - 1199)), -1.2)
        XCTAssertNil(Hardware.signedCurrent(NSNumber(value: 1_000_000)))
        XCTAssertNil(Hardware.signedCurrent(nil))
    }
    func testPowerUnitsAndAdapterAreDistinct() {
        let result = Hardware.parseBattery(["Voltage": 12000, "InstantAmperage": 2000, "ExternalConnected": true, "IsCharging": true,
                                            "AdapterDetails": ["Watts": 60, "AdapterVoltage": 20000, "Current": 3000],
                                            "PowerTelemetryData": ["SystemPowerIn": 42300]])
        XCTAssertEqual(result.voltage, 12)
        XCTAssertEqual(result.current, 2)
        XCTAssertEqual(result.batteryPower, 24)
        XCTAssertEqual(result.adapterWatts, 60)
        XCTAssertEqual(result.inputPower, 42.3)
        XCTAssertEqual(result.powerLabel, "电池充入")
        let unplugged = Hardware.parseBattery(["Voltage": 12000, "Amperage": -1000, "AdapterDetails": ["Watts": 60]])
        XCTAssertNil(unplugged.adapterWatts)
        XCTAssertEqual(unplugged.batteryPower, -12)
    }
    func testMalformedBatteryFieldsAndUnavailableValuesStayMissing() {
        let result = Hardware.parseBattery(["Voltage": Double.nan, "Temperature": 800000, "CycleCount": -1,
                                            "BatteryData": ["DesignCapacity": 0, "NominalChargeCapacity": 900]])
        XCTAssertNil(result.voltage); XCTAssertNil(result.temperature); XCTAssertNil(result.cycles)
        XCTAssertNil(result.capacityPercent); XCTAssertNil(result.current); XCTAssertNil(result.batteryPower)
    }
    func testCellVoltagesMustMatchPack() {
        XCTAssertEqual(SensorReader.validatedCells([4.096,4.098,4.097], packVoltage: 12.292).count, 3)
        XCTAssertTrue(SensorReader.validatedCells([0.016,0.528,0.272], packVoltage: 12.292).isEmpty)
        XCTAssertTrue(SensorReader.validatedCells([4.1,4.1], packVoltage: 12.292).isEmpty)
        XCTAssertTrue(SensorReader.validatedCells([.nan,4.1], packVoltage: 8.2).isEmpty)
        XCTAssertTrue(SensorReader.validatedCells([4.1], packVoltage: nil).isEmpty)
    }
}
