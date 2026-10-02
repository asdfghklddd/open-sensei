import XCTest
@testable import OpenSensei

final class PolicyAndToolsTests: XCTestCase {
    func testProcessCPUConvertsAppleSiliconMachTicks() {
        XCTAssertEqual(ProcessReader.cpuPercent(ticks: 24_000_000, seconds: 1, numerator: 125, denominator: 3), 100, accuracy: 0.001)
        XCTAssertEqual(ProcessReader.cpuPercent(ticks: 1_000_000_000, seconds: 2, numerator: 1, denominator: 1), 50, accuracy: 0.001)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenSenseiTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testCadenceVisibilitySleepAndLowPower() {
        XCTAssertEqual(ResourcePolicy.interval(visible: true, asleep: false, lowPower: false, active: 2, idle: 30), 2)
        XCTAssertEqual(ResourcePolicy.interval(visible: false, asleep: false, lowPower: false, active: 2, idle: 30), 30)
        XCTAssertEqual(ResourcePolicy.interval(visible: true, asleep: false, lowPower: true, active: 1, idle: 30), 5)
        XCTAssertEqual(ResourcePolicy.interval(visible: false, asleep: false, lowPower: true, active: 1, idle: 30), 60)
        XCTAssertNil(ResourcePolicy.interval(visible: true, asleep: true, lowPower: false, active: 2, idle: 30))
        XCTAssertNil(ResourcePolicy.interval(visible: false, asleep: false, lowPower: false, active: 2, idle: 0))
    }
    func testBatteryHistoryNeverCreatesAFileUntilRecording() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("daily.json")
        let store = BatteryHistoryStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.size, 0)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(store.record(capacity: 91, cycles: 100, date: date))
        XCTAssertFalse(store.record(capacity: 90, cycles: 101, date: date.addingTimeInterval(1)))
        for day in 1...130 {
            _ = store.record(capacity: 90, cycles: 100 + day, date: date.addingTimeInterval(Double(day) * 86400))
        }
        XCTAssertEqual(store.entries.count, 90)
        XCTAssertLessThan(store.size, ResourcePolicy.batteryFileLimit)
        XCTAssertEqual(BatteryHistoryStore(url: url).entries, store.entries)
        try store.clear()
        XCTAssertEqual(store.size, 0)
        XCTAssertTrue(store.entries.isEmpty)
    }
    func testBatteryHistoryRejectsCorruptOversizedAndNonFiniteData() throws {
        let url = try temporaryDirectory().appendingPathComponent("daily.json")
        try Data(repeating: 65, count: ResourcePolicy.batteryFileLimit + 1).write(to: url)
        let store = BatteryHistoryStore(url: url)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.record(capacity: .nan, cycles: nil))
        XCTAssertFalse(store.record(capacity: 150, cycles: nil))
    }
    func testScannerLimitsCancellationAndSymlinks() throws {
        let root = try temporaryDirectory()
        for i in 0..<230 { try Data(repeating: UInt8(i % 255), count: (i + 1) * 256).write(to: root.appendingPathComponent("file\(i)")) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let report = StorageScanner.scan(root, token: CancellationToken())
        XCTAssertEqual(report.files.count, ResourcePolicy.scanResultLimit)
        XCTAssertFalse(report.partial)
        XCTAssertTrue(report.files.allSatisfy { !$0.url.path.contains("outside") })
        XCTAssertGreaterThanOrEqual(report.files.first!.bytes, report.files.last!.bytes)
        let bounded = StorageScanner.scan(root, token: CancellationToken(), entryLimit: 5)
        XCTAssertEqual(bounded.visited, 5)
        XCTAssertTrue(bounded.partial)
        let token = CancellationToken(); token.cancel()
        XCTAssertEqual(StorageScanner.scan(root, token: token).visited, 0)
    }
    func testTrashValidationRejectsChangedAndEscapingFiles() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: url)
        let record = StorageScanner.scan(root, token: CancellationToken()).files[0]
        XCTAssertNoThrow(try StorageScanner.validate(record, inside: root))
        XCTAssertThrowsError(try StorageScanner.validate(record, inside: root.appendingPathComponent("subfolder")))
        try Data(repeating: 42, count: 100_000).write(to: url)
        XCTAssertThrowsError(try StorageScanner.validate(record, inside: root))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try StorageScanner.validate(record, inside: root))
    }
    func testBundleIDMatchingRejectsTraversalAndOnlyMatchesExactPaths() throws {
        XCTAssertTrue(AppInventory.validBundleID("com.example.Editor"))
        XCTAssertFalse(AppInventory.validBundleID("../../Documents"))
        XCTAssertFalse(AppInventory.validBundleID("com.example/../../Documents"))
        XCTAssertFalse(AppInventory.validBundleID("com.github.Electron"))
        let root = try temporaryDirectory()
        let cache = root.appendingPathComponent("Library/Caches/com.example.Editor")
        let neighbor = root.appendingPathComponent("Library/Caches/com.example.EditorExtra")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        let app = InstalledApp(url: root.appendingPathComponent("Editor.app"), name: "Editor", bundleID: "com.example.Editor", version: "1")
        let candidates = AppInventory.candidates(for: app, home: root)
        XCTAssertTrue(candidates.contains { $0.url.path == cache.path })
        XCTAssertFalse(candidates.contains { $0.url.path == neighbor.path })
    }
    func testBenchmarkCleansTemporaryFilesOnSuccessAndCancel() throws {
        let root = try temporaryDirectory()
        let result = try DiskBenchmark.run(in: root, token: CancellationToken())
        XCTAssertGreaterThan(result.write, 0)
        XCTAssertGreaterThan(result.read, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try DiskBenchmark.run(in: root, token: token))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @MainActor func testMultipleSurfacesAndSleepState() throws {
        let monitor = Monitor(historyStore: BatteryHistoryStore(url: try temporaryDirectory().appendingPathComponent("daily.json")))
        monitor.setSurface("popover", visible: true)
        monitor.setSurface("center", visible: true)
        monitor.setSurface("popover", visible: false)
        XCTAssertTrue(monitor.visible)
        monitor.setAsleep(true)
        XCTAssertNil(monitor.effectiveInterval)
        monitor.setAsleep(false)
        XCTAssertNotNil(monitor.effectiveInterval)
        monitor.setSurface("center", visible: false)
        XCTAssertFalse(monitor.visible)
        XCTAssertTrue(monitor.cpuHistory.isEmpty)
    }
}
