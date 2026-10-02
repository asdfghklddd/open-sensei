import XCTest
import Darwin
@testable import OpenSensei

final class OptimizationTests: XCTestCase {
    func testDriveReportMergesSharedPhysicalDriveAndPreservesUnavailableFields() throws {
        let root: [String: Any] = ["SPStorageDataType": [
            ["_name": "Data", "mount_point": "/System/Volumes/Data", "size_in_bytes": 1000, "free_space_in_bytes": 200,
             "physical_drive": ["device_name": "Test SSD", "smart_status": "Verified", "protocol": "PCI-Express"]],
            ["_name": "System", "mount_point": "/", "size_in_bytes": 1000, "free_space_in_bytes": 200,
             "physical_drive": ["device_name": "Test SSD", "smart_status": "Verified"]],
            ["_name": "External", "mount_point": "/Volumes/External", "file_system": "ExFAT"]
        ], "SPNVMeDataType": [["_items": [["_name": "Test SSD", "smart_status": "Verified", "spnvme_trim_support": "Yes", "size": "1 TB"]]]]]
        let report = try SystemReport.parseDrives(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(report.drives.count, 1)
        XCTAssertEqual(report.drives[0].trim, "Yes")
        XCTAssertEqual(report.drives[0].capacity, "1 TB")
        XCTAssertEqual(report.volumes.count, 3)
        XCTAssertNil(report.volumes.first { $0.name == "External" }?.free)
    }
    func testPanelOrderRejectsUnknownAndDuplicateItemsWithoutLosingModules() {
        let order = DashboardModule.normalized(["battery", "battery", "unknown", "cpu"])
        XCTAssertEqual(order.first, .battery)
        XCTAssertEqual(order.count, DashboardModule.allCases.count)
        XCTAssertEqual(Set(order), Set(DashboardModule.allCases))
    }
    func testRoutingBufferSkipsShortAddressMessagesBeforeInterfaces() {
        var address: [UInt8] = [8, 0, UInt8(RTM_VERSION), UInt8(RTM_NEWADDR), 0, 0, 0, 0]
        var info = if_msghdr2()
        info.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size); info.ifm_type = UInt8(RTM_IFINFO2)
        info.ifm_index = 3; info.ifm_flags = IFF_UP | IFF_RUNNING
        info.ifm_data.ifi_ibytes = 1234; info.ifm_data.ifi_obytes = 5678
        withUnsafeBytes(of: &info) { address.append(contentsOf: $0) }
        let reading = NetworkReader.decode(address, length: address.count) { $0 == 3 ? "en0" : nil }
        XCTAssertEqual(reading.interfaces.map(\.name), ["en0"])
        XCTAssertEqual(reading.counters["en0"]?.received, 1234)
        XCTAssertTrue(NetworkReader.decode([0, 0, 0, 0], length: 4) { _ in "en0" }.interfaces.isEmpty)
        XCTAssertTrue(NetworkReader.decode([255, 255, 0, 0], length: 4000) { _ in "en0" }.interfaces.isEmpty)
    }
    func testLargestFilesMatchesFullSortAtBoundedSize() {
        var heap = LargestFiles(limit: 200)
        let expected = (0..<12_000).map { Int64(($0 * 7919) % 65_537) }
        for (i, bytes) in expected.enumerated() {
            heap.insert(FileRecord(url: URL(fileURLWithPath: "/test/\(i)"), bytes: bytes, modified: nil, identity: ""))
            XCTAssertLessThanOrEqual(heap.heap.count, 200)
        }
        XCTAssertEqual(heap.sorted.map(\.bytes), Array(expected.sorted(by: >).prefix(200)))
        var empty = LargestFiles(limit: 0)
        empty.insert(FileRecord(url: URL(fileURLWithPath: "/test"), bytes: 99, modified: nil, identity: ""))
        XCTAssertTrue(empty.sorted.isEmpty)
    }
    func testCancellationRunsHandlersOnceAndHandlesAlreadyCancelledRegistration() {
        let token = CancellationToken()
        var called = 0
        _ = token.onCancel { called += 1 }
        let removed = token.onCancel { called += 100 }
        token.removeHandler(removed)
        token.cancel(); token.cancel()
        XCTAssertEqual(called, 1)
        _ = token.onCancel { called += 1 }
        XCTAssertEqual(called, 2)
    }
    func testCancellingSystemReportStopsItsOwnedProcessPromptly() throws {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SystemReport.run("/bin/sleep", ["10"], token: token))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }
    func testProcessGroupingUsesOuterAppAndKeepsDifferentLocationsSeparate() {
        XCTAssertEqual(ProcessGrouping.appPath("/Applications/Editor.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "/Applications/Editor.app")
        XCTAssertNil(ProcessGrouping.appPath("/usr/libexec/helper"))
        let rows = [ProcessRow(id: 1, name: "Editor", cpu: 30, memory: 100, appPath: "/Applications/Editor.app"),
                    ProcessRow(id: 2, name: "Helper", cpu: 15, memory: 50, appPath: "/Applications/Editor.app"),
                    ProcessRow(id: 3, name: "Editor", cpu: 2, memory: 20, appPath: "/Other/Editor.app"),
                    ProcessRow(id: 4, name: "helper", cpu: 1, memory: 10)]
        let groups = ProcessGrouping.rows(rows, grouped: true)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first { $0.id == "/Applications/Editor.app" }?.cpu, 45)
        XCTAssertEqual(groups.first { $0.id == "/Applications/Editor.app" }?.memory, 150)
        XCTAssertEqual(ProcessGrouping.rows(rows, grouped: false).count, 4)
    }
    func testNetworkAggregationExcludesTunnelsAndInterfaceSwitchCannotDoubleCount() {
        let counters = ["en0": NetworkCounter(received: 100, sent: 10), "en5": NetworkCounter(received: 200, sent: 20), "utun3": NetworkCounter(received: 100, sent: 10)]
        XCTAssertEqual(Set(NetworkReader.select(counters, interface: "all").keys), ["en0", "en5"])
        XCTAssertEqual(Set(NetworkReader.select(counters, interface: "utun3").keys), ["utun3"])
        XCTAssertTrue(NetworkReader.select(counters, interface: "en99").isEmpty)
        let sampler = Sampler()
        let sample = sampler.sample(domains: [.network], interface: "en9999")
        XCTAssertEqual(sample.stamps[.network]?.condition, .unavailable)
        XCTAssertEqual(sample.work.smcCalls, 0)
    }
    func testDiskActivityIsOnDemandAndUsesNoSMC() {
        let sampler = Sampler()
        XCTAssertNil(sampler.sample(domains: [.cpu]).stamps[.activity])
        let sample = sampler.sample(domains: [.activity])
        XCTAssertEqual(sample.work.domains, [.activity])
        XCTAssertEqual(sample.work.smcCalls, 0)
        XCTAssertNil(sample.activity.read)
    }
    func testCheckUsesMemoryPressureAndRejectsStaleValues() {
        let date = Date(timeIntervalSince1970: 1000)
        var sample = Snapshot()
        sample.memoryUsed = sample.memoryTotal * 0.98
        sample.memoryPressure = "正常"; sample.swap = 2_000_000_000
        sample.stamps[.memory] = ReadingStamp(date: date, condition: .ready)
        let finding = StateCheck.make(sample, now: date).findings.first { $0.id == "memory" }
        XCTAssertEqual(finding?.level, .good)
        sample.memoryPressure = "很高"
        XCTAssertEqual(StateCheck.make(sample, now: date).findings.first { $0.id == "memory" }?.level, .attention)
        XCTAssertEqual(StateCheck.make(sample, now: date.addingTimeInterval(60)).findings.first { $0.id == "memory" }?.level, .unknown)
    }
    func testAlertNeedsSustainedConditionAndHonorsCooldownAndSleepGap() {
        var gate = AlertGate()
        XCTAssertFalse(gate.evaluate(.memory, active: true, now: 0))
        XCTAssertFalse(gate.evaluate(.memory, active: true, now: 30))
        XCTAssertTrue(gate.evaluate(.memory, active: true, now: 60))
        XCTAssertFalse(gate.evaluate(.memory, active: true, now: 90))
        XCTAssertFalse(gate.evaluate(.memory, active: false, now: 100))
        XCTAssertFalse(gate.evaluate(.memory, active: true, now: 120))
        XCTAssertFalse(gate.evaluate(.memory, active: true, now: 180))
        XCTAssertFalse(gate.evaluate(.memory, active: true, now: 3600))
        XCTAssertFalse(gate.evaluate(.memory, active: true, now: 3630))
        XCTAssertTrue(gate.evaluate(.memory, active: true, now: 3660))
        gate.resetDwell()
        XCTAssertFalse(gate.evaluate(.space, active: true, now: 3700))
        XCTAssertFalse(gate.evaluate(.space, active: nil, now: 3730))
        XCTAssertFalse(gate.evaluate(.space, active: true, now: 3760))
    }
    func testAlertRulesDoNotAssumeMissingDataIsZero() {
        var sample = Snapshot()
        XCTAssertNil(AlertGate.condition(.space, snapshot: sample))
        sample.stamps[.storage] = ReadingStamp(date: Date(), condition: .ready)
        sample.diskFree = 5_000_000_000; sample.diskTotal = 1_000_000_000_000
        XCTAssertEqual(AlertGate.condition(.space, snapshot: sample), true)
        sample.diskFree = nil
        XCTAssertNil(AlertGate.condition(.space, snapshot: sample))
        let plan = SamplingPlan.make(surfaces: [:], menu: "icon", active: 2, idle: 30, asleep: false, lowPower: false, alerts: [.memory, .storage])
        XCTAssertEqual(plan.intervals, [.memory: 30, .storage: 60])
    }
}
