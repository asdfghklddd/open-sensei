import XCTest
@testable import OpenSensei

final class InsightsTests: XCTestCase {
    func testThermalHistoryIsBoundedAndMissingReadingsProduceGaps() {
        var history = ThermalHistory()
        for i in 0..<80 {
            let snapshot = SensorSnapshot(available: true, temperatures: [
                TemperatureReading(id: "Tp01", value: 60 + Double(i % 5)),
                TemperatureReading(id: "Tg05", value: 55),
                TemperatureReading(id: "TB0T", value: 30)
            ], updated: Date(timeIntervalSince1970: Double(i)))
            history.append(snapshot)
            history.append(snapshot) // A cached sensor read must not duplicate the sample.
        }
        XCTAssertEqual(history.points.count, 60)
        XCTAssertEqual(history.points.first?.id, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(history.points.last?.cpu, 64)
        history.append(SensorSnapshot(updated: Date(timeIntervalSince1970: 80)))
        XCTAssertNil(history.points.last?.cpu)
        XCTAssertNil(history.points.last?.gpu)
        history.append(SensorSnapshot(updated: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(history.points.last?.id, Date(timeIntervalSince1970: 80))
        history.clear()
        XCTAssertTrue(history.points.isEmpty)
    }

    func testSnapshotReportUnitsMissingDataAndByteBudget() {
        var snapshot = Snapshot()
        snapshot.cpu = 0.125
        snapshot.battery = Battery(percent: 0.85, charging: false, pluggedIn: true)
        snapshot.health.voltage = 12
        snapshot.health.current = -1.5
        snapshot.sensors = SensorSnapshot(available: true, fans: [FanReading(id: 0, rpm: 2500, minimum: 1200, maximum: 6000, target: 2500, mode: 1)], updated: Date(timeIntervalSince1970: 10))
        snapshot.stamps[.fans] = ReadingStamp(date: Date(timeIntervalSince1970: 10), condition: .ready)
        snapshot.stamps[.cells] = ReadingStamp(date: Date(timeIntervalSince1970: 20), condition: .ready)
        let text = SnapshotReport.make(snapshot, chip: "M1 Pro", cadence: "每 2 秒", version: "0.4.0")
        XCTAssertTrue(text.contains("12.5%"))
        XCTAssertTrue(text.contains("85%"))
        XCTAssertTrue(text.contains("-18.00 W"))
        XCTAssertTrue(text.contains("1970-01-01T00:00:10Z"))
        XCTAssertTrue(text.contains("1970-01-01T00:00:20Z"))
        XCTAssertTrue(text.contains("下载：未提供"))
        XCTAssertTrue(text.contains("2500 RPM"))
        XCTAssertTrue(text.contains("GPU：未提供"))
        XCTAssertLessThan(text.utf8.count, SnapshotReport.byteLimit)
        snapshot.cpu = .nan
        snapshot.memoryPressure = String(repeating: "界", count: 9000)
        let oversized = SnapshotReport.make(snapshot, chip: String(repeating: "🧪", count: 10000), cadence: "暂停", version: String(repeating: "x", count: 20000))
        XCTAssertLessThanOrEqual(oversized.utf8.count, SnapshotReport.byteLimit)
        XCTAssertFalse(oversized.lowercased().contains("nan"))
    }

    func testFanCancelledBeforeReadyCannotStartAndUnknownModeIsNotAutomatic() {
        var state = FanSessionState()
        XCTAssertEqual(state.title(for: SensorSnapshot()), "暂无读数")
        state.start(); XCTAssertTrue(state.busy)
        XCTAssertEqual(state.stopLabel, "取消授权")
        state.stop()
        state.receive("READY", duration: 300)
        state.receive("ACTIVE manual", duration: 300)
        XCTAssertFalse(state.mayHaveControlled)
        XCTAssertFalse(state.active)
        state.receive("FINISHED", duration: 300)
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.error)
        let unknown = SensorSnapshot(available: true, fans: [FanReading(id: 0, rpm: 0, minimum: 1200, maximum: 6000, target: nil, mode: nil)])
        XCTAssertEqual(state.title(for: unknown), "模式未知")
    }

    func testFanRestorationMustBeExplicitAndLateActiveCannotUndoStopping() {
        var state = FanSessionState()
        state.start(); state.receive("READY", duration: 300)
        state.receive("ACTIVE manual", duration: 300, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(state.endsAt, Date(timeIntervalSince1970: 300))
        state.stop(); state.receive("ACTIVE thermal", duration: 300)
        XCTAssertEqual(state.phase, .stopping)
        state.receive("RESTORED", duration: 300); state.receive("FINISHED", duration: 300)
        XCTAssertTrue(state.restored); XCTAssertNil(state.error); XCTAssertFalse(state.busy)
        XCTAssertEqual(state.status, "已确认恢复系统自动调节")
        state.start(); state.receive("READY", duration: 300); state.receive("FINISHED", duration: 300)
        XCTAssertNotNil(state.error); XCTAssertTrue(state.requiresRecovery)
        state.start(); XCTAssertFalse(state.busy)
    }

    func testFanFailedWritesAndAuthorizationTimeoutHaveDifferentRecoveryStates() {
        var state = FanSessionState()
        state.start(); state.receive("ERROR authorization timeout", duration: 300); state.receive("FINISHED", duration: 300)
        XCTAssertTrue(state.error?.contains("两分钟") == true)
        XCTAssertFalse(state.requiresRecovery)
        state.start(); state.receive("READY", duration: 300)
        state.receive("ERROR control failed; restored", duration: 300); state.receive("FINISHED", duration: 300)
        XCTAssertTrue(state.restored); XCTAssertFalse(state.requiresRecovery)
        XCTAssertEqual(state.status, "已确认恢复系统自动调节")
        let actualError = state.error
        state.receive("ERROR authorization", duration: 300)
        XCTAssertEqual(state.error, actualError)
        state.start(); state.receive("READY", duration: 300)
        state.receive("ERROR restore failed", duration: 300); state.receive("FINISHED", duration: 300)
        XCTAssertTrue(state.requiresRecovery)
        XCTAssertEqual(state.title(for: SensorSnapshot(available: true)), "待确认恢复")
    }
}
