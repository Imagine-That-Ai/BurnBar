import Foundation
import OpenBurnBarLogParsers

/// Process-wide memory watchdog — the last line of defense behind the
/// per-pass `ParserResourceGovernor` ceilings.
///
/// On 2026-07-16 an ungoverned parse pass took the app to a 25.4GB physical
/// footprint; with system swap already near capacity, the whole machine
/// stopped responding. The governor now aborts parse passes at
/// `ParserResourcePolicy.memoryCeilingBytes`, but that only covers governed
/// parsers. This watchdog samples the process footprint on a slow cadence
/// (plus OS memory-pressure events) and:
///
///  * logs a warning when the footprint crosses the soft limit;
///  * at the critical threshold — footprint past the parse ceiling, meaning
///    some ungoverned subsystem is ballooning — logs a fault, cancels the
///    heavy background refresh work, and surfaces the condition in parser
///    health so it is visible in the UI rather than in Activity Monitor.
///
/// The watchdog never terminates the app: shedding the heavy work and making
/// the condition loud is the safe reaction; exiting would lose user state.
@MainActor
final class MemoryFootprintWatchdog {
    /// Footprint that logs a single warning per crossing.
    static let softLimitBytes = ParserResourcePolicy.memorySoftLimitBytes
    /// Footprint at which background refresh work is shed. Sits above the
    /// parse-pass ceiling so the governor always gets to act first.
    static let criticalLimitBytes: Int64 = ParserResourcePolicy.memoryCeilingBytes + 2 * 1024 * 1024 * 1024
    /// Sample cadence. Cheap (one task_info syscall) — the cost is nil.
    static let sampleInterval: Duration = .seconds(30)
    /// Re-arm thresholds once the footprint falls back below this fraction.
    private static let rearmFraction = 0.75

    private var monitorTask: Task<Void, Never>?
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var softLimitTripped = false
    private var criticalTripped = false
    private weak var aggregator: UsageAggregator?

    init() {}

    func start(aggregator: UsageAggregator) {
        self.aggregator = aggregator
        guard monitorTask == nil else { return }

        monitorTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.sample(trigger: "timer")
                try? await Task.sleep(for: Self.sampleInterval) // try?-ok(cancellation only)
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            Task { @MainActor [weak self] in
                await self?.sample(trigger: event.contains(.critical) ? "os_pressure_critical" : "os_pressure_warning")
            }
        }
        source.activate()
        pressureSource = source
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    private func sample(trigger: String) async {
        let footprint = ParserResourceGovernor.currentPhysicalFootprint()
        guard footprint > 0 else { return }
        let footprintMB = footprint / (1024 * 1024)

        if criticalTripped || softLimitTripped {
            let rearmBelow = Int64(Double(Self.softLimitBytes) * Self.rearmFraction)
            if footprint < rearmBelow {
                if criticalTripped {
                    aggregator?.memoryPressureRecovered()
                }
                softLimitTripped = false
                criticalTripped = false
            }
        }

        if footprint > Self.criticalLimitBytes, !criticalTripped {
            criticalTripped = true
            AppLogger.parser.error(
                "memory_watchdog_critical",
                metadata: [
                    "footprint_mb": String(footprintMB),
                    "limit_mb": String(Self.criticalLimitBytes / (1024 * 1024)),
                    "trigger": trigger
                ]
            )
            aggregator?.shedBackgroundWorkForMemoryPressure(footprintMB: footprintMB)
            return
        }

        if footprint > Self.softLimitBytes, !softLimitTripped {
            softLimitTripped = true
            AppLogger.parser.notice(
                "memory_watchdog_soft_limit",
                metadata: [
                    "footprint_mb": String(footprintMB),
                    "limit_mb": String(Self.softLimitBytes / (1024 * 1024)),
                    "trigger": trigger
                ]
            )
        }
    }
}
