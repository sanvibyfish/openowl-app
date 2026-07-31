import Darwin
import Foundation
import Testing
@testable import openOwl

@Suite("Resource Monitor")
struct ResourceMonitorTests {
    private let policy = ResourceMonitorPolicy(
        memoryLimitBytes: 8 * 1_073_741_824,
        memoryGrowthLimitBytes: 2 * 1_073_741_824,
        memoryGrowthWindow: 10 * 60,
        cpuLimitPercent: 400,
        cpuConsecutiveSamples: 3,
        alertCooldown: 30 * 60
    )

    @Test func memoryLimit_alertsImmediatelyAndThenCoolsDown() {
        var engine = ResourceAlertEngine(policy: policy)
        let identity = ProcessIdentity(pid: 101, startTime: 1)
        let start = Date(timeIntervalSince1970: 1_000)

        let first = engine.evaluate([
            snapshot(identity: identity, residentGiB: 8, at: start)
        ])
        #expect(first.count == 1)
        #expect(first.first?.kind == .memoryLimit)

        let repeated = engine.evaluate([
            snapshot(identity: identity, residentGiB: 9, at: start.addingTimeInterval(60))
        ])
        #expect(repeated.isEmpty)
    }

    @Test func memoryGrowth_comparesAgainstRecentMinimum() {
        var engine = ResourceAlertEngine(policy: policy)
        let identity = ProcessIdentity(pid: 202, startTime: 2)
        let start = Date(timeIntervalSince1970: 2_000)

        #expect(engine.evaluate([
            snapshot(identity: identity, residentGiB: 1, at: start)
        ]).isEmpty)

        let alerts = engine.evaluate([
            snapshot(
                identity: identity,
                residentGiB: 3,
                at: start.addingTimeInterval(10 * 60)
            )
        ])

        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .memoryGrowth)
        #expect(alerts.first?.memoryGrowthBytes == 2 * 1_073_741_824)
    }

    @Test func cpuLimit_requiresThreeConsecutiveHighSamples() {
        var engine = ResourceAlertEngine(policy: policy)
        let identity = ProcessIdentity(pid: 303, startTime: 3)
        let start = Date(timeIntervalSince1970: 3_000)
        let cpuPerMinute = UInt64(240 * 1_000_000_000)

        #expect(engine.evaluate([
            snapshot(identity: identity, cpuTimeNanoseconds: 0, at: start)
        ]).isEmpty)
        #expect(engine.evaluate([
            snapshot(
                identity: identity,
                cpuTimeNanoseconds: cpuPerMinute,
                at: start.addingTimeInterval(60)
            )
        ]).isEmpty)
        #expect(engine.evaluate([
            snapshot(
                identity: identity,
                cpuTimeNanoseconds: cpuPerMinute * 2,
                at: start.addingTimeInterval(120)
            )
        ]).isEmpty)

        let alerts = engine.evaluate([
            snapshot(
                identity: identity,
                cpuTimeNanoseconds: cpuPerMinute * 3,
                at: start.addingTimeInterval(180)
            )
        ])

        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .cpuLimit)
        #expect(Int(alerts.first?.cpuPercent ?? 0) == 400)
    }

    @Test func pidReuse_doesNotInheritPreviousProcessHistory() {
        var engine = ResourceAlertEngine(policy: policy)
        let start = Date(timeIntervalSince1970: 4_000)

        #expect(engine.evaluate([
            snapshot(
                identity: ProcessIdentity(pid: 404, startTime: 10),
                residentGiB: 1,
                at: start
            )
        ]).isEmpty)

        let alerts = engine.evaluate([
            snapshot(
                identity: ProcessIdentity(pid: 404, startTime: 11),
                residentGiB: 3,
                at: start.addingTimeInterval(60)
            )
        ])
        #expect(alerts.isEmpty)
    }

    @Test func samplerCapturesTheCurrentProcess() throws {
        let capturedAt = Date(timeIntervalSince1970: 5_000)
        let snapshots = ProcessResourceSampler().capture(at: capturedAt)
        let current = try #require(
            snapshots.first(where: { $0.identity.pid == getpid() })
        )

        #expect(current.name.isEmpty == false)
        #expect(current.residentBytes > 0)
        #expect(current.capturedAt == capturedAt)
    }

    @Test func samplerConvertsMachAbsoluteTimeToNanoseconds() {
        let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)
        let nanoseconds = ProcessResourceSampler.nanoseconds(
            fromAbsoluteTime: 24_000_000,
            timebase: timebase
        )

        #expect(nanoseconds == 1_000_000_000)
    }

    private func snapshot(
        identity: ProcessIdentity,
        residentGiB: UInt64 = 1,
        cpuTimeNanoseconds: UInt64 = 0,
        at date: Date
    ) -> ProcessResourceSnapshot {
        ProcessResourceSnapshot(
            identity: identity,
            name: "Test Process",
            residentBytes: residentGiB * 1_073_741_824,
            cpuTimeNanoseconds: cpuTimeNanoseconds,
            capturedAt: date
        )
    }
}
