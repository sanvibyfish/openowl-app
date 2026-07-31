import Darwin
import Foundation
import UserNotifications

struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startTime: UInt64
}

struct ProcessResourceSnapshot: Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let residentBytes: UInt64
    let cpuTimeNanoseconds: UInt64
    let capturedAt: Date
}

struct ResourceMonitorPolicy: Sendable {
    let memoryLimitBytes: UInt64
    let memoryGrowthLimitBytes: UInt64
    let memoryGrowthWindow: TimeInterval
    let cpuLimitPercent: Double
    let cpuConsecutiveSamples: Int
    let alertCooldown: TimeInterval

    static let standard = ResourceMonitorPolicy(
        memoryLimitBytes: 8 * 1_073_741_824,
        memoryGrowthLimitBytes: 2 * 1_073_741_824,
        memoryGrowthWindow: 10 * 60,
        cpuLimitPercent: 400,
        cpuConsecutiveSamples: 3,
        alertCooldown: 30 * 60
    )
}

enum ResourceAlertKind: String, Equatable, Sendable {
    case memoryLimit
    case memoryGrowth
    case cpuLimit
}

struct ResourceAlert: Equatable, Sendable {
    let kind: ResourceAlertKind
    let identity: ProcessIdentity
    let processName: String
    let residentBytes: UInt64
    let memoryGrowthBytes: UInt64?
    let cpuPercent: Double?
    let detectedAt: Date
}

struct ResourceAlertEngine {
    private struct MemoryPoint {
        let capturedAt: Date
        let residentBytes: UInt64
    }

    private struct AlertIdentity: Hashable {
        let process: ProcessIdentity
        let kind: ResourceAlertKind
    }

    private let policy: ResourceMonitorPolicy
    private var memoryHistory: [ProcessIdentity: [MemoryPoint]] = [:]
    private var previousSnapshots: [ProcessIdentity: ProcessResourceSnapshot] = [:]
    private var consecutiveHighCPUSamples: [ProcessIdentity: Int] = [:]
    private var lastAlertDates: [AlertIdentity: Date] = [:]

    init(policy: ResourceMonitorPolicy = .standard) {
        self.policy = policy
    }

    mutating func evaluate(_ snapshots: [ProcessResourceSnapshot]) -> [ResourceAlert] {
        let liveProcesses = Set(snapshots.map(\.identity))
        removeStateForExitedProcesses(liveProcesses)

        var alerts: [ResourceAlert] = []
        for snapshot in snapshots.sorted(by: { $0.identity.pid < $1.identity.pid }) {
            if let memoryAlert = evaluateMemory(snapshot) {
                alerts.append(memoryAlert)
            }
            if let cpuAlert = evaluateCPU(snapshot) {
                alerts.append(cpuAlert)
            }
            previousSnapshots[snapshot.identity] = snapshot
        }
        return alerts
    }

    private mutating func evaluateMemory(_ snapshot: ProcessResourceSnapshot) -> ResourceAlert? {
        var history = memoryHistory[snapshot.identity] ?? []
        history.removeAll {
            snapshot.capturedAt.timeIntervalSince($0.capturedAt) > policy.memoryGrowthWindow
        }

        let recentMinimum = history.map(\.residentBytes).min()
        history.append(
            MemoryPoint(
                capturedAt: snapshot.capturedAt,
                residentBytes: snapshot.residentBytes
            )
        )
        memoryHistory[snapshot.identity] = history

        if snapshot.residentBytes >= policy.memoryLimitBytes {
            return makeAlert(
                kind: .memoryLimit,
                snapshot: snapshot,
                memoryGrowthBytes: nil,
                cpuPercent: nil
            )
        }

        guard let recentMinimum,
              snapshot.residentBytes >= recentMinimum,
              snapshot.residentBytes - recentMinimum >= policy.memoryGrowthLimitBytes else {
            return nil
        }

        return makeAlert(
            kind: .memoryGrowth,
            snapshot: snapshot,
            memoryGrowthBytes: snapshot.residentBytes - recentMinimum,
            cpuPercent: nil
        )
    }

    private mutating func evaluateCPU(_ snapshot: ProcessResourceSnapshot) -> ResourceAlert? {
        guard let previous = previousSnapshots[snapshot.identity] else {
            consecutiveHighCPUSamples[snapshot.identity] = 0
            return nil
        }

        let elapsed = snapshot.capturedAt.timeIntervalSince(previous.capturedAt)
        guard elapsed > 0,
              snapshot.cpuTimeNanoseconds >= previous.cpuTimeNanoseconds else {
            consecutiveHighCPUSamples[snapshot.identity] = 0
            return nil
        }

        let cpuDelta = snapshot.cpuTimeNanoseconds - previous.cpuTimeNanoseconds
        let cpuPercent = Double(cpuDelta) / 1_000_000_000 / elapsed * 100

        guard cpuPercent >= policy.cpuLimitPercent else {
            consecutiveHighCPUSamples[snapshot.identity] = 0
            return nil
        }

        let highSampleCount = (consecutiveHighCPUSamples[snapshot.identity] ?? 0) + 1
        consecutiveHighCPUSamples[snapshot.identity] = highSampleCount
        guard highSampleCount >= policy.cpuConsecutiveSamples else { return nil }

        return makeAlert(
            kind: .cpuLimit,
            snapshot: snapshot,
            memoryGrowthBytes: nil,
            cpuPercent: cpuPercent
        )
    }

    private mutating func makeAlert(
        kind: ResourceAlertKind,
        snapshot: ProcessResourceSnapshot,
        memoryGrowthBytes: UInt64?,
        cpuPercent: Double?
    ) -> ResourceAlert? {
        let identity = AlertIdentity(process: snapshot.identity, kind: kind)
        if let lastAlertDate = lastAlertDates[identity],
           snapshot.capturedAt.timeIntervalSince(lastAlertDate) < policy.alertCooldown {
            return nil
        }

        lastAlertDates[identity] = snapshot.capturedAt
        return ResourceAlert(
            kind: kind,
            identity: snapshot.identity,
            processName: snapshot.name,
            residentBytes: snapshot.residentBytes,
            memoryGrowthBytes: memoryGrowthBytes,
            cpuPercent: cpuPercent,
            detectedAt: snapshot.capturedAt
        )
    }

    private mutating func removeStateForExitedProcesses(_ liveProcesses: Set<ProcessIdentity>) {
        memoryHistory = memoryHistory.filter { liveProcesses.contains($0.key) }
        previousSnapshots = previousSnapshots.filter { liveProcesses.contains($0.key) }
        consecutiveHighCPUSamples = consecutiveHighCPUSamples.filter {
            liveProcesses.contains($0.key)
        }
        lastAlertDates = lastAlertDates.filter { liveProcesses.contains($0.key.process) }
    }
}

struct ProcessResourceSampler: Sendable {
    private static let systemTimebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    private let userID = getuid()

    func capture(at capturedAt: Date = Date()) -> [ProcessResourceSnapshot] {
        let estimatedProcessCount = proc_listallpids(nil, 0)
        guard estimatedProcessCount > 0 else { return [] }

        var processIDs = [pid_t](
            repeating: 0,
            count: Int(estimatedProcessCount) + 32
        )
        let processCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard processCount > 0 else { return [] }

        return processIDs.prefix(Int(processCount)).compactMap { processID in
            snapshot(processID: processID, capturedAt: capturedAt)
        }
    }

    private func snapshot(
        processID: pid_t,
        capturedAt: Date
    ) -> ProcessResourceSnapshot? {
        guard processID > 0 else { return nil }

        var info = proc_taskallinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        let returnedSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processID,
                PROC_PIDTASKALLINFO,
                0,
                $0,
                expectedSize
            )
        }
        guard returnedSize == expectedSize, info.pbsd.pbi_uid == userID else {
            return nil
        }

        let startTime = info.pbsd.pbi_start_tvsec * 1_000_000
            + UInt64(info.pbsd.pbi_start_tvusec)
        let cpuTimeTicks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
        return ProcessResourceSnapshot(
            identity: ProcessIdentity(pid: processID, startTime: startTime),
            name: processName(processID),
            residentBytes: info.ptinfo.pti_resident_size,
            cpuTimeNanoseconds: Self.nanoseconds(
                fromAbsoluteTime: cpuTimeTicks,
                timebase: Self.systemTimebase
            ),
            capturedAt: capturedAt
        )
    }

    static func nanoseconds(
        fromAbsoluteTime ticks: UInt64,
        timebase: mach_timebase_info_data_t
    ) -> UInt64 {
        let numerator = UInt64(timebase.numer)
        let denominator = UInt64(timebase.denom)
        guard numerator > 0, denominator > 0 else { return 0 }

        let wholeTicks = ticks / denominator
        let remainderTicks = ticks % denominator
        let (wholeNanoseconds, wholeOverflow) = wholeTicks.multipliedReportingOverflow(
            by: numerator
        )
        guard !wholeOverflow else { return UInt64.max }

        let remainderNanoseconds = remainderTicks * numerator / denominator
        let (nanoseconds, totalOverflow) = wholeNanoseconds.addingReportingOverflow(
            remainderNanoseconds
        )
        return totalOverflow ? UInt64.max : nanoseconds
    }

    private func processName(_ processID: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_name(processID, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return "Process \(processID)" }
        return String(cString: buffer)
    }
}

@MainActor
final class ResourceMonitor {
    private let samplingInterval: Duration
    private var alertEngine: ResourceAlertEngine
    private var monitoringTask: Task<Void, Never>?
    /// Called when an alert concerns this process (openOwl). Wire to surface dump.
    var onSelfProcessAlert: ((ResourceAlert) -> Void)?

    init(
        policy: ResourceMonitorPolicy = .standard,
        samplingInterval: Duration = .seconds(60)
    ) {
        self.alertEngine = ResourceAlertEngine(policy: policy)
        self.samplingInterval = samplingInterval
    }

    func start() {
        guard monitoringTask == nil else { return }
        AppLogger.log("resource-monitor", "started")

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleAndNotify()
                // Cancellation is the only way this sleep fails, and `stop()`
                // already clears the handle. The task must not clear it itself:
                // after a stop/start cycle the handle belongs to the *new* task,
                // and nilling it there would orphan that task and let the next
                // `start()` run a second loop over the same alert engine.
                do {
                    try await Task.sleep(for: self.samplingInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
        AppLogger.log("resource-monitor", "stopped")
    }

    private func sampleAndNotify() async {
        let snapshots = await Task.detached(priority: .utility) {
            ProcessResourceSampler().capture()
        }.value

        guard !snapshots.isEmpty else {
            AppLogger.log("resource-monitor", "sampling returned no accessible processes")
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for alert in alertEngine.evaluate(snapshots) {
            AppLogger.log("resource-monitor", alert.logMessage)
            deliverNotification(for: alert)
            if alert.identity.pid == selfPID {
                onSelfProcessAlert?(alert)
            }
        }
    }

    private func deliverNotification(for alert: ResourceAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.notificationTitle
        content.body = alert.notificationBody
        content.sound = .default
        content.userInfo = [
            "pid": Int(alert.identity.pid),
            "kind": alert.kind.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: "resource-\(alert.kind.rawValue)-\(alert.identity.pid)-\(alert.identity.startTime)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogger.log(
                    "resource-monitor",
                    "notification failed: \(error.localizedDescription)"
                )
            }
        }
    }
}

private extension ResourceAlert {
    var notificationTitle: String {
        switch kind {
        case .memoryLimit:
            return "内存占用异常"
        case .memoryGrowth:
            return "内存快速增长"
        case .cpuLimit:
            return "CPU 持续过高"
        }
    }

    var notificationBody: String {
        let process = "\(processName) (PID \(identity.pid))"
        switch kind {
        case .memoryLimit:
            return "\(process)\n当前占用 \(Self.formatGiB(residentBytes))"
        case .memoryGrowth:
            return "\(process)\n近 10 分钟增长 \(Self.formatGiB(memoryGrowthBytes ?? 0))"
        case .cpuLimit:
            return "\(process)\nCPU \(Int((cpuPercent ?? 0).rounded()))%，已持续约 3 分钟"
        }
    }

    var logMessage: String {
        switch kind {
        case .memoryLimit:
            return "\(processName) pid=\(identity.pid) memory=\(Self.formatGiB(residentBytes))"
        case .memoryGrowth:
            return "\(processName) pid=\(identity.pid) memory-growth=\(Self.formatGiB(memoryGrowthBytes ?? 0))"
        case .cpuLimit:
            return "\(processName) pid=\(identity.pid) cpu=\(Int((cpuPercent ?? 0).rounded()))%"
        }
    }

    static func formatGiB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
