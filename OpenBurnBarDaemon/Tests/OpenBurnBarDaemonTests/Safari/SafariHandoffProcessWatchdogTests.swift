import Foundation
import XCTest

@testable import OpenBurnBarDaemon

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class SafariHandoffProcessWatchdogTests: XCTestCase {
    func testNormalDaemonArgumentsDoNotEnterPrivateWatchdogMode() {
        XCTAssertFalse(
            SafariHandoffProcessWatchdog.runIfRequested(arguments: [])
        )
        XCTAssertFalse(
            SafariHandoffProcessWatchdog.runIfRequested(
                arguments: ["serve", "--foreground"]
            )
        )
        XCTAssertFalse(
            SafariHandoffProcessWatchdog.runIfRequested(
                arguments: [
                    "--normal-daemon-argument",
                    SafariHandoffProcessWatchdog.marker,
                ]
            )
        )
    }

    func testPrivateProtocolDescriptorsAreDedicatedBoundedAndDistinct() {
        let descriptors = [
            SafariHandoffProcessWatchdog.packageFD,
            SafariHandoffProcessWatchdog.livenessFD,
            SafariHandoffProcessWatchdog.commandFD,
            SafariHandoffProcessWatchdog.configurationFD,
            SafariHandoffProcessWatchdog.statusFD,
            SafariHandoffProcessWatchdog.stdoutFD,
            SafariHandoffProcessWatchdog.stderrFD,
        ]

        XCTAssertEqual(
            SafariHandoffProcessWatchdog.marker,
            "--safari-handoff-watchdog-v1"
        )
        XCTAssertEqual(Set(descriptors).count, descriptors.count)
        XCTAssertTrue(descriptors.allSatisfy { $0 > STDERR_FILENO })
        XCTAssertEqual(
            SafariHandoffProcessWatchdog.maximumEnvelopeBytes,
            512 * 1024
        )
        XCTAssertEqual(
            SafariHandoffProcessWatchdog.maximumStatusBytes,
            16 * 1024
        )
        XCTAssertGreaterThan(
            SafariHandoffProcessWatchdog.maximumEnvelopeBytes,
            SafariHandoffProcessWatchdog.maximumStatusBytes
        )
    }

    func testLaunchEnvelopeRoundTripsExactPinnedAuthority() throws {
        let generation = UUID()
        let packageIdentity =
            SafariHandoffProcessSupervisor.FilesystemIdentity(
                device: 17,
                inode: 23
            )
        let executable =
            SafariHandoffProcessSupervisor.ValidatedExecutable(
                path: "/opt/openburnbar/bin/agent.js",
                identity: .init(device: 31, inode: 37),
                size: 41,
                modificationSeconds: 43,
                modificationNanoseconds: 47,
                launchPath: "/usr/bin/node",
                launchArguments: ["/opt/openburnbar/bin/agent.js"],
                components: [
                    .init(
                        path: "/opt/openburnbar/bin/agent.js",
                        identity: .init(device: 31, inode: 37),
                        size: 41,
                        modificationSeconds: 43,
                        modificationNanoseconds: 47
                    ),
                    .init(
                        path: "/usr/bin/env",
                        identity: .init(device: 53, inode: 59),
                        size: 61,
                        modificationSeconds: 67,
                        modificationNanoseconds: 71
                    ),
                    .init(
                        path: "/usr/bin/node",
                        identity: .init(device: 73, inode: 79),
                        size: 83,
                        modificationSeconds: 89,
                        modificationNanoseconds: 97
                    ),
                ]
            )
        let envelope = SafariHandoffProcessWatchdog.Envelope(
            generation: generation,
            packageIdentity: packageIdentity,
            executable: executable,
            arguments: ["--version", "--json"],
            environment: [
                "HOME": "/Users/test",
                "PATH": "/usr/bin:/bin",
                "TERM": "dumb",
            ]
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            SafariHandoffProcessWatchdog.Envelope.self,
            from: data
        )

        XCTAssertLessThanOrEqual(
            data.count,
            SafariHandoffProcessWatchdog.maximumEnvelopeBytes
        )
        XCTAssertEqual(decoded.generation, generation)
        XCTAssertEqual(decoded.packageIdentity, packageIdentity)
        XCTAssertEqual(decoded.executable, executable)
        XCTAssertEqual(decoded.executable.launchPath, "/usr/bin/node")
        XCTAssertEqual(
            decoded.executable.launchArguments,
            ["/opt/openburnbar/bin/agent.js"]
        )
        XCTAssertEqual(
            decoded.executable.components.map(\.path),
            [
                "/opt/openburnbar/bin/agent.js",
                "/usr/bin/env",
                "/usr/bin/node",
            ]
        )
        XCTAssertEqual(decoded.arguments, ["--version", "--json"])
        XCTAssertEqual(decoded.environment["HOME"], "/Users/test")
        XCTAssertEqual(decoded.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(decoded.environment["TERM"], "dumb")
    }

    func testReadyTerminalAndLaunchFailureMessagesRoundTripExactly()
        throws
    {
        let messages = [
            SafariHandoffProcessWatchdog.Message(
                kind: .ready,
                processGroupID: 10_002,
                waitStatus: nil,
                error: nil
            ),
            SafariHandoffProcessWatchdog.Message(
                kind: .terminal,
                processGroupID: 10_002,
                waitStatus: Int32(7 << 8),
                error: nil
            ),
            SafariHandoffProcessWatchdog.Message(
                kind: .launchFailed,
                processGroupID: nil,
                waitStatus: nil,
                error: "watchdog_launch_rejected"
            ),
        ]

        for message in messages {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(
                SafariHandoffProcessWatchdog.Message.self,
                from: data
            )
            XCTAssertLessThan(
                data.count,
                SafariHandoffProcessWatchdog.maximumStatusBytes
            )
            XCTAssertEqual(decoded.kind.rawValue, message.kind.rawValue)
            XCTAssertEqual(
                decoded.processGroupID,
                message.processGroupID
            )
            XCTAssertEqual(decoded.waitStatus, message.waitStatus)
            XCTAssertEqual(decoded.error, message.error)
        }
    }

    func testMessageKindWireNamesRemainFailClosedAndUnambiguous() {
        XCTAssertEqual(
            SafariHandoffProcessWatchdog.MessageKind.ready.rawValue,
            "ready"
        )
        XCTAssertEqual(
            SafariHandoffProcessWatchdog.MessageKind.terminal.rawValue,
            "terminal"
        )
        XCTAssertEqual(
            SafariHandoffProcessWatchdog.MessageKind.launchFailed.rawValue,
            "launch_failed"
        )
    }

    #if os(macOS)
        func testNaturalExitReapsChildAndContainsRemainingExactGroup() {
            let childPID: pid_t = 4_201
            let status = Int32(12 << 8)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [
                    .init(result: childPID, status: status)
                ]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, status)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -childPID, signal: SIGTERM),
                    .init(target: -childPID, signal: SIGKILL),
                ]
            )
            XCTAssertEqual(probe.sleepsSnapshot(), [100_000])
            XCTAssertEqual(probe.waitBlockingCallCount, 0)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testLivenessEOFRequestsTermThenKillAndRetriesInterruptedReap() {
            let childPID: pid_t = 4_202
            let killedStatus = Int32(SIGKILL)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [
                    .init(result: 0),
                    .init(result: 0),
                ],
                waitBlocking: [
                    .init(result: -1, error: EINTR),
                    .init(result: childPID, status: killedStatus),
                ],
                poll: [
                    .init(
                        result: 1,
                        livenessEvents: Int16(POLLHUP)
                    ),
                    .init(result: 0),
                ],
                uptimeNanoseconds: [100, 100, 111]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                livenessDescriptor: 51,
                commandDescriptor: 52,
                graceNanoseconds: 10,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, killedStatus)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -childPID, signal: SIGTERM),
                    .init(target: -childPID, signal: SIGKILL),
                ]
            )
            XCTAssertEqual(probe.waitBlockingCallCount, 2)
            XCTAssertTrue(probe.readDescriptorsSnapshot().isEmpty)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testCommandReadRequestsImmediateExactGroupContainment() {
            let childPID: pid_t = 4_203
            let killedStatus = Int32(SIGKILL)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [.init(result: 0)],
                waitBlocking: [
                    .init(result: childPID, status: killedStatus)
                ],
                poll: [
                    .init(
                        result: 1,
                        commandEvents: Int16(POLLIN)
                    )
                ],
                uptimeNanoseconds: [200, 200]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                livenessDescriptor: 61,
                commandDescriptor: 62,
                graceNanoseconds: 0,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, killedStatus)
            XCTAssertEqual(probe.readDescriptorsSnapshot(), [62])
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -childPID, signal: SIGTERM),
                    .init(target: -childPID, signal: SIGKILL),
                ]
            )
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testInterruptedWaitAndPollRetryBeforeNaturalReap() {
            let childPID: pid_t = 4_204
            let status = Int32(3 << 8)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [
                    .init(result: -1, error: EINTR),
                    .init(result: 0),
                    .init(result: childPID, status: status),
                ],
                poll: [
                    .init(result: -1, error: EINTR),
                    .init(result: 0),
                ]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, status)
            XCTAssertEqual(probe.waitNoHangCallCount, 3)
            XCTAssertEqual(probe.pollCallCount, 2)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -childPID, signal: SIGTERM),
                    .init(target: -childPID, signal: SIGKILL),
                ]
            )
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testOpenLivenessWithNoCommandDoesNotSignalBeforeNaturalExit() {
            let childPID: pid_t = 4_206
            let status = Int32(0)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [
                    .init(result: 0),
                    .init(result: childPID, status: status),
                ],
                poll: [.init(result: 0)]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, status)
            let events = probe.eventsSnapshot()
            let pollIndex = events.firstIndex(of: "poll")
            let reapIndex = events.firstIndex(
                of: "wait-nohang:\(childPID)"
            )
            let firstSignalIndex = events.firstIndex(
                of: "signal:\(-childPID):\(SIGTERM)"
            )
            if let pollIndex, let reapIndex, let firstSignalIndex {
                XCTAssertLessThan(pollIndex, reapIndex)
                XCTAssertLessThan(reapIndex, firstSignalIndex)
            } else {
                XCTFail("Expected poll, reap, and containment events: \(events)")
            }
            XCTAssertTrue(probe.readDescriptorsSnapshot().isEmpty)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testPollFailureContainsGroupAndRetriesBlockingReap() {
            let childPID: pid_t = 4_205
            let killedStatus = Int32(SIGKILL)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [.init(result: 0)],
                waitBlocking: [
                    .init(result: -1, error: EINTR),
                    .init(result: childPID, status: killedStatus),
                ],
                poll: [.init(result: -1, error: EIO)]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, killedStatus)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -childPID, signal: SIGTERM),
                    .init(target: -childPID, signal: SIGKILL),
                ]
            )
            XCTAssertEqual(probe.waitBlockingCallCount, 2)
            XCTAssertTrue(probe.sleepsSnapshot().isEmpty)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testNonInterruptedWaitFailureNeverFabricatesSuccessfulExit() {
            let childPID: pid_t = 4_207
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [.init(result: -1, error: ECHILD)],
                waitBlocking: [.init(result: -1, error: ECHILD)]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                runtime: probe.runtime
            )

            XCTAssertNil(
                observed,
                "A failed wait monitor must not be decoded as exit status zero"
            )
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -childPID, signal: SIGTERM),
                    .init(target: -childPID, signal: SIGKILL),
                ]
            )
            XCTAssertEqual(probe.waitNoHangCallCount, 1)
            XCTAssertEqual(probe.waitBlockingCallCount, 1)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testPollAndBlockingWaitFailureRemainMonitorFailure() {
            let childPID: pid_t = 4_208
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [.init(result: 0)],
                waitBlocking: [.init(result: -1, error: EIO)],
                poll: [.init(result: -1, error: EIO)]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                processGroupID: childPID,
                runtime: probe.runtime
            )

            XCTAssertNil(observed)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -childPID, signal: SIGTERM),
                    .init(target: -childPID, signal: SIGKILL),
                ]
            )
            XCTAssertEqual(probe.waitNoHangCallCount, 1)
            XCTAssertEqual(probe.waitBlockingCallCount, 1)
            XCTAssertEqual(probe.pollCallCount, 1)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testUnsafeOrMismatchedProcessGroupsAreNeverObservedOrSignalled() {
            XCTAssertFalse(
                SafariHandoffProcessWatchdog.isSafeProcessGroup(
                    0,
                    currentGroup: 100
                )
            )
            XCTAssertFalse(
                SafariHandoffProcessWatchdog.isSafeProcessGroup(
                    1,
                    currentGroup: 100
                )
            )
            XCTAssertFalse(
                SafariHandoffProcessWatchdog.isSafeProcessGroup(
                    -2,
                    currentGroup: 100
                )
            )
            XCTAssertFalse(
                SafariHandoffProcessWatchdog.isSafeProcessGroup(
                    100,
                    currentGroup: 100
                )
            )
            XCTAssertTrue(
                SafariHandoffProcessWatchdog.isSafeProcessGroup(
                    101,
                    currentGroup: 100
                )
            )

            for (childPID, processGroupID, currentGroup) in [
                (pid_t(0), pid_t(0), pid_t(100)),
                (pid_t(1), pid_t(1), pid_t(100)),
                (pid_t(101), pid_t(1), pid_t(100)),
                (pid_t(101), pid_t(-2), pid_t(100)),
                (pid_t(101), pid_t(100), pid_t(100)),
            ] {
                let probe = SafariWatchdogMonitorProbe(
                    currentProcessGroup: currentGroup
                )
                XCTAssertNil(
                    SafariHandoffProcessWatchdog.monitor(
                        childPID: childPID,
                        processGroupID: processGroupID,
                        runtime: probe.runtime
                    )
                )
                SafariHandoffProcessWatchdog.terminateRemainingGroup(
                    processGroupID,
                    excludingReapedChild: true,
                    runtime: probe.runtime
                )
                XCTAssertTrue(probe.signalsSnapshot().isEmpty)
                XCTAssertEqual(probe.waitNoHangCallCount, 0)
                XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
            }

            let mismatchedProbe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 100
            )
            XCTAssertNil(
                SafariHandoffProcessWatchdog.monitor(
                    childPID: 101,
                    processGroupID: 102,
                    runtime: mismatchedProbe.runtime
                )
            )
            XCTAssertTrue(mismatchedProbe.signalsSnapshot().isEmpty)
            XCTAssertEqual(mismatchedProbe.waitNoHangCallCount, 0)
            XCTAssertTrue(mismatchedProbe.unexpectedCallsSnapshot().isEmpty)
        }
    #endif
}

#if os(macOS)
    private final class SafariWatchdogMonitorProbe: @unchecked Sendable {
        struct WaitStep {
            let result: pid_t
            let status: Int32
            let error: Int32

            init(
                result: pid_t,
                status: Int32 = 0,
                error: Int32 = 0
            ) {
                self.result = result
                self.status = status
                self.error = error
            }
        }

        struct PollStep {
            let result: Int32
            let livenessEvents: Int16
            let commandEvents: Int16
            let error: Int32

            init(
                result: Int32,
                livenessEvents: Int16 = 0,
                commandEvents: Int16 = 0,
                error: Int32 = 0
            ) {
                self.result = result
                self.livenessEvents = livenessEvents
                self.commandEvents = commandEvents
                self.error = error
            }
        }

        struct SignalRecord: Equatable {
            let target: pid_t
            let signal: Int32
        }

        private let lock = NSLock()
        private let processGroup: pid_t
        private var waitNoHangSteps: [WaitStep]
        private var waitBlockingSteps: [WaitStep]
        private var pollSteps: [PollStep]
        private var uptimes: [UInt64]
        private var lastUptime: UInt64
        private var lastError: Int32 = 0
        private var signals: [SignalRecord] = []
        private var sleeps: [useconds_t] = []
        private var readDescriptors: [Int32] = []
        private var events: [String] = []
        private var unexpectedCalls: [String] = []
        private var _waitNoHangCallCount = 0
        private var _waitBlockingCallCount = 0
        private var _pollCallCount = 0

        init(
            currentProcessGroup: pid_t,
            waitNoHang: [WaitStep] = [],
            waitBlocking: [WaitStep] = [],
            poll: [PollStep] = [],
            uptimeNanoseconds: [UInt64] = [0]
        ) {
            processGroup = currentProcessGroup
            waitNoHangSteps = waitNoHang
            waitBlockingSteps = waitBlocking
            pollSteps = poll
            uptimes = uptimeNanoseconds
            lastUptime = uptimeNanoseconds.last ?? 0
        }

        var runtime: SafariHandoffProcessWatchdog.MonitorRuntime {
            .init(
                waitNoHang: { [self] childPID, status in
                    wait(
                        childPID: childPID,
                        status: status,
                        blocking: false
                    )
                },
                waitBlocking: { [self] childPID, status in
                    wait(
                        childPID: childPID,
                        status: status,
                        blocking: true
                    )
                },
                pollEvents: { [self] descriptors, timeout in
                    poll(
                        descriptors: &descriptors,
                        timeout: timeout
                    )
                },
                readByte: { [self] descriptor, byte in
                    read(descriptor: descriptor, byte: byte)
                },
                signal: { [self] target, signal in
                    recordSignal(target: target, signal: signal)
                    return 0
                },
                uptimeNanoseconds: { [self] in uptime() },
                sleepMicroseconds: { [self] duration in
                    recordSleep(duration)
                },
                currentErrno: { [self] in currentError() },
                currentProcessGroup: { [self] in processGroup }
            )
        }

        var waitNoHangCallCount: Int {
            locked { _waitNoHangCallCount }
        }

        var waitBlockingCallCount: Int {
            locked { _waitBlockingCallCount }
        }

        var pollCallCount: Int {
            locked { _pollCallCount }
        }

        func signalsSnapshot() -> [SignalRecord] {
            locked { signals }
        }

        func sleepsSnapshot() -> [useconds_t] {
            locked { sleeps }
        }

        func readDescriptorsSnapshot() -> [Int32] {
            locked { readDescriptors }
        }

        func unexpectedCallsSnapshot() -> [String] {
            locked { unexpectedCalls }
        }

        func eventsSnapshot() -> [String] {
            locked { events }
        }

        private func wait(
            childPID: pid_t,
            status: UnsafeMutablePointer<Int32>,
            blocking: Bool
        ) -> pid_t {
            locked {
                if blocking {
                    _waitBlockingCallCount += 1
                } else {
                    _waitNoHangCallCount += 1
                }
                var steps = blocking ? waitBlockingSteps : waitNoHangSteps
                guard steps.isEmpty == false else {
                    unexpectedCalls.append(
                        blocking
                            ? "unexpected blocking wait"
                            : "unexpected nonblocking wait"
                    )
                    lastError = ECHILD
                    return -1
                }
                let step = steps.removeFirst()
                if blocking {
                    waitBlockingSteps = steps
                } else {
                    waitNoHangSteps = steps
                }
                status.pointee = step.status
                lastError = step.error
                events.append(
                    "\(blocking ? "wait-blocking" : "wait-nohang"):\(step.result)"
                )
                if step.result > 0, step.result != childPID {
                    unexpectedCalls.append("wait returned a foreign child")
                }
                return step.result
            }
        }

        private func poll(
            descriptors: inout [pollfd],
            timeout: Int32
        ) -> Int32 {
            locked {
                _pollCallCount += 1
                guard pollSteps.isEmpty == false else {
                    unexpectedCalls.append("unexpected poll")
                    lastError = EIO
                    return -1
                }
                guard descriptors.count == 2, timeout == 50 else {
                    unexpectedCalls.append("invalid poll shape")
                    lastError = EINVAL
                    return -1
                }
                let step = pollSteps.removeFirst()
                descriptors[0].revents = step.livenessEvents
                descriptors[1].revents = step.commandEvents
                lastError = step.error
                events.append("poll")
                return step.result
            }
        }

        private func read(
            descriptor: Int32,
            byte: UnsafeMutablePointer<UInt8>
        ) -> Int {
            locked {
                readDescriptors.append(descriptor)
                events.append("read:\(descriptor)")
                byte.pointee = 1
                lastError = 0
                return 1
            }
        }

        private func recordSignal(target: pid_t, signal: Int32) {
            locked {
                signals.append(.init(target: target, signal: signal))
                events.append("signal:\(target):\(signal)")
            }
        }

        private func uptime() -> UInt64 {
            locked {
                if uptimes.isEmpty == false {
                    lastUptime = uptimes.removeFirst()
                }
                return lastUptime
            }
        }

        private func recordSleep(_ duration: useconds_t) {
            locked { sleeps.append(duration) }
        }

        private func currentError() -> Int32 {
            locked { lastError }
        }

        @discardableResult
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
#endif
