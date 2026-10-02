import XCTest
@testable import OpenSensei

final class MetricsTests: XCTestCase {
    func testCPUUsesDeltaAndIdle() {
        XCTAssertEqual(Sampler.cpuUsage(old: [100, 100, 100, 0], new: [120, 110, 170, 0])!, 0.3, accuracy: 0.0001)
        XCTAssertNil(Sampler.cpuUsage(old: [0, 0, 0, 0], new: [0, 0, 0, 0]))
    }
    func testCPUCountersWrap() {
        let old: [UInt32] = [.max - 4, 0, .max - 4, 0]
        let new: [UInt32] = [5, 0, 5, 0]
        XCTAssertEqual(Sampler.cpuUsage(old: old, new: new)!, 0.5, accuracy: 0.0001)
    }
    func testNetworkResetAndNewInterfacesDoNotSpike() {
        let old = ["en0": NetworkCounter(received: 1000, sent: 500)]
        let new = ["en0": NetworkCounter(received: 3000, sent: 100), "en1": NetworkCounter(received: 9_000_000, sent: 9_000_000)]
        let rate = NetworkRate.between(old, new, seconds: 2)
        XCTAssertEqual(rate.download, 1000)
        XCTAssertEqual(rate.upload, 0)
        XCTAssertEqual(NetworkRate.between(old, new, seconds: 0).download, 0)
    }
    func testLiveSampling() {
        let sampler = Sampler()
        let first = sampler.sample()
        XCTAssertNil(first.cpu)
        XCTAssertGreaterThan(first.memoryUsed ?? 0, 0)
        XCTAssertLessThanOrEqual(first.memoryUsed ?? .infinity, first.memoryTotal)
        XCTAssertGreaterThan(first.diskTotal ?? 0, 0)
        var next = first
        // macOS can return the same cached host ticks during very short intervals.
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.35)
            next = sampler.sample()
            if next.cpu != nil { break }
        }
        XCTAssertNotNil(next.cpu)
        XCTAssertTrue((0...1).contains(next.cpu ?? -1))
        print("Live metrics: CPU=\(Format.percent(next.cpu))%, RAM=\(Format.bytes(next.memoryUsed ?? 0)), disk free=\(Format.bytes(next.diskFree ?? 0)), battery=\(next.battery.map { Format.percent($0.percent) } ?? "none")")
    }
}
