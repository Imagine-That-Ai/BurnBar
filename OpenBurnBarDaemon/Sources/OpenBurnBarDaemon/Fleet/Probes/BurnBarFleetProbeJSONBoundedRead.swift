import Darwin
import Foundation

extension BurnBarFleetProbeJSON {
    /// Bounded JSON read (per-probe timeout seam, VAL-FLEET-019): opens the
    /// file non-blocking and polls for readability up to `timeoutSeconds`,
    /// then reads and parses. A blocking path (FIFO) or a read that exceeds
    /// the bound throws `BurnBarFleetProbeReadError.timedOut` so the probe
    /// degrades typed without stalling the tick.
    ///
    /// `deadlineUptimeNanoseconds` is a monotonic whole-probe deadline. When
    /// supplied, both the initial poll and every drain/poll iteration share
    /// that deadline; a sequence of slow reads cannot multiply the budget.
    public static func readJSONBounded(
        at path: String,
        timeoutSeconds: TimeInterval = BurnBarFleetProbeConstants.perProbeTimeoutSeconds,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) throws -> Any {
        let fileDescriptor = open(path, O_RDONLY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw BurnBarFleetProbeReadError.unreadable(errno)
        }
        defer { close(fileDescriptor) }

        let readDeadline = deadlineUptimeNanoseconds
            ?? monotonicDeadline(after: timeoutSeconds)
        var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard let timeoutMilliseconds = pollTimeoutMilliseconds(
            timeoutSeconds: timeoutSeconds,
            deadlineUptimeNanoseconds: readDeadline
        ) else {
            throw BurnBarFleetProbeReadError.timedOut
        }
        let pollResult = poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard pollResult > 0 else {
            throw BurnBarFleetProbeReadError.timedOut
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if DispatchTime.now().uptimeNanoseconds >= readDeadline {
                throw BurnBarFleetProbeReadError.timedOut
            }
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    guard let timeoutMilliseconds = pollTimeoutMilliseconds(
                        timeoutSeconds: timeoutSeconds,
                        deadlineUptimeNanoseconds: readDeadline
                    ) else {
                        throw BurnBarFleetProbeReadError.timedOut
                    }
                    pollDescriptor.revents = 0
                    let pollResult = poll(&pollDescriptor, 1, timeoutMilliseconds)
                    guard pollResult > 0 else {
                        throw BurnBarFleetProbeReadError.timedOut
                    }
                    continue
                }
                throw BurnBarFleetProbeReadError.unreadable(errno)
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    /// Returns a monotonic deadline for a bounded sequence of signal reads.
    public static func monotonicDeadline(after seconds: TimeInterval) -> UInt64 {
        let finiteSeconds = seconds.isFinite ? max(0, seconds) : 0
        let nanoseconds = UInt64(min(finiteSeconds, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    private static func pollTimeoutMilliseconds(
        timeoutSeconds: TimeInterval,
        deadlineUptimeNanoseconds: UInt64?
    ) -> Int32? {
        let boundedTimeoutSeconds = timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 0
        let timeoutNanoseconds = UInt64(
            min(boundedTimeoutSeconds, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000
        )
        let requestedDeadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        let effectiveDeadline = min(
            requestedDeadline,
            deadlineUptimeNanoseconds ?? requestedDeadline
        )
        let now = DispatchTime.now().uptimeNanoseconds
        guard effectiveDeadline > now else { return nil }
        let remainingNanoseconds = effectiveDeadline - now
        let milliseconds = (remainingNanoseconds + 999_999) / 1_000_000
        return Int32(min(max(1, milliseconds), UInt64(Int32.max)))
    }
}
