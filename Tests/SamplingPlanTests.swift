import XCTest
@testable import OpenSensei

final class SamplingPlanTests: XCTestCase {
    func testIconOnlyDoesNoPeriodicWorkAndCPUOnlyRequestsCPU() {
        let idle = SamplingPlan.make(surfaces: [:], menu: "icon", active: 2, idle: 30, asleep: false, lowPower: false)
        XCTAssertTrue(idle.intervals.isEmpty)
        let cpu = SamplingPlan.make(surfaces: [:], menu: "cpu", active: 2, idle: 30, asleep: false, lowPower: false)
        XCTAssertEqual(cpu.intervals, [.cpu: 30])
        XCTAssertTrue(SamplingPlan.make(surfaces: [:], menu: "cpu", active: 2, idle: 0, asleep: false, lowPower: false).intervals.isEmpty)
    }
    func testMultipleViewsShareDemandAndBatteryPageDoesNotRequireGPUOrCoreSensors() {
        let battery = SamplingPlan.make(surfaces: ["center": [.battery, .cells, .batteryTemperature]], menu: "cpu", active: 2, idle: 30, asleep: false, lowPower: false)
        XCTAssertEqual(battery.intervals[.cpu], 30)
        XCTAssertEqual(battery.intervals[.cells], 10)
        XCTAssertNil(battery.intervals[.gpu]); XCTAssertNil(battery.intervals[.thermal]); XCTAssertNil(battery.intervals[.fans])
        let shared = SamplingPlan.make(surfaces: ["center": [.battery, .cells], "panel": [.cpu, .battery, .gpu]], menu: "cpu", active: 2, idle: 30, asleep: false, lowPower: true)
        XCTAssertEqual(shared.intervals[.cpu], 5)
        XCTAssertEqual(shared.intervals[.battery], 5)
        XCTAssertEqual(shared.intervals.count, 4)
        XCTAssertTrue(SamplingPlan.make(surfaces: ["panel": MetricDomain.legacy], menu: "cpu", active: 2, idle: 30, asleep: true, lowPower: false).intervals.isEmpty)
    }
    func testSchedulerUsesIndependentDeadlinesAndDoesNotCatchUpAfterStall() {
        var schedule = SamplingSchedule()
        schedule.update(SamplingPlan(intervals: [.cpu: 2, .cells: 10, .storage: 60]), now: 100)
        XCTAssertEqual(schedule.takeDue(now: 100), [.cpu, .cells, .storage])
        XCTAssertEqual(schedule.takeDue(now: 102), [.cpu])
        XCTAssertTrue(schedule.takeDue(now: 103).isEmpty)
        XCTAssertEqual(schedule.takeDue(now: 110), [.cpu, .cells])
        XCTAssertEqual(schedule.takeDue(now: 1000), [.cpu, .cells, .storage])
        XCTAssertEqual(schedule.next, 1002)
        XCTAssertTrue(schedule.takeDue(now: 1000).isEmpty)
    }
    func testClosingViewRemovesSensorDeadlineAndDoesNotBlankCPUWithAnExtraRead() {
        var schedule = SamplingSchedule()
        schedule.update(SamplingPlan(intervals: [.cpu: 2, .thermal: 2]), now: 100)
        _ = schedule.takeDue(now: 100)
        schedule.update(SamplingPlan(intervals: [.cpu: 30]), now: 101)
        XCTAssertNil(schedule.deadlines[.thermal])
        XCTAssertTrue(schedule.takeDue(now: 101).isEmpty)
        XCTAssertEqual(schedule.next, 131)
        schedule.update(SamplingPlan(intervals: [.cpu: 2, .thermal: 2]), now: 110)
        XCTAssertEqual(schedule.takeDue(now: 110), [.cpu, .thermal])
    }
    func testManualRefreshDoesNotAddDisabledDomains() {
        var schedule = SamplingSchedule()
        schedule.update(SamplingPlan(intervals: [.cpu: 30]), now: 0)
        _ = schedule.takeDue(now: 0)
        schedule.request([.cpu, .gpu, .thermal], at: 1)
        XCTAssertEqual(schedule.takeDue(now: 1), [.cpu])
        XCTAssertEqual(schedule.plan.intervals.count, 1)
    }
    func testActualSamplerSkipsAllSMCAndUnrequestedReaders() {
        let sampler = Sampler()
        let empty = sampler.sample(domains: [])
        XCTAssertTrue(empty.work.domains.isEmpty); XCTAssertEqual(empty.work.smcCalls, 0)
        let cpu = sampler.sample(domains: [.cpu])
        XCTAssertEqual(cpu.work.domains, [.cpu]); XCTAssertEqual(cpu.work.smcCalls, 0)
        XCTAssertNil(cpu.stamps[.battery]); XCTAssertNil(cpu.stamps[.memory]); XCTAssertNil(cpu.stamps[.thermal])
        let battery = sampler.sample(domains: [.battery])
        XCTAssertEqual(battery.work.domains, [.battery]); XCTAssertEqual(battery.work.smcCalls, 0)
        XCTAssertEqual(battery.work.totals[.cpu], 1); XCTAssertEqual(battery.work.totals[.battery], 1)
    }
    func testSensorMergeDoesNotReplaceOtherDomainsAndCanClearFailedRead() {
        var sample = SensorSnapshot(available: true, fans: [FanReading(id: 0, rpm: 2000, minimum: 1200, maximum: 6000, target: 2000, mode: 0)],
                                    temperatures: [TemperatureReading(id: "Tp01", value: 60), TemperatureReading(id: "TB0T", value: 30)])
        sample.merge(SensorSnapshot(temperatures: [TemperatureReading(id: "TB0T", value: 32)]), demand: .battery)
        XCTAssertEqual(sample.hottest, 60); XCTAssertEqual(sample.batteryTemperature, 32); XCTAssertEqual(sample.fans.count, 1)
        sample.merge(SensorSnapshot(), demand: .core)
        XCTAssertNil(sample.hottest); XCTAssertEqual(sample.batteryTemperature, 32)
    }
    @MainActor func testModuleToggleChangesRealPlanWithoutLosingOtherSurfaceNeeds() {
        let monitor = Monitor()
        monitor.menuMetric = "icon"; monitor.batteryHistoryEnabled = false
        monitor.showGPU = false; monitor.showNetwork = false; monitor.showBattery = false; monitor.showTemperatures = false
        monitor.setSurface("popover", visible: true)
        XCTAssertEqual(Set(monitor.currentPlan.intervals.keys), [.cpu, .memory, .storage])
        monitor.setSurface("center", visible: true, domains: [.thermal, .fans])
        XCTAssertNotNil(monitor.currentPlan.intervals[.thermal])
        monitor.setSurface("popover", visible: false)
        XCTAssertEqual(Set(monitor.currentPlan.intervals.keys), [.thermal, .fans])
        monitor.setSurface("center", visible: false)
        XCTAssertNil(monitor.effectiveInterval)
    }
}
