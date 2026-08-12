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
            SafariHandoffProcessWatchdog.sentinelLifetimeFD,
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
        let containmentIdentity =
            SafariHandoffProcessSupervisor.ProcessIdentity(
                processID: 10_001,
                processGroupID: 10_001,
                startSeconds: 101,
                startMicroseconds: 202
            )
        let envelope = SafariHandoffProcessWatchdog.Envelope(
            generation: generation,
            packageIdentity: packageIdentity,
            containmentIdentity: containmentIdentity,
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
        XCTAssertEqual(
            decoded.containmentIdentity,
            containmentIdentity
        )
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
                containmentIdentity: .init(
                    processID: 10_002,
                    processGroupID: 10_002,
                    startSeconds: 100,
                    startMicroseconds: 200
                ),
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
            XCTAssertEqual(
                decoded.containmentIdentity,
                message.containmentIdentity
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

    func testStatusFrameDecoderBoundsPartialAndMultipleMessages()
        throws
    {
        let ready = SafariHandoffProcessWatchdog.Message(
            kind: .ready,
            processGroupID: 10_002,
            containmentIdentity: .init(
                processID: 10_002,
                processGroupID: 10_002,
                startSeconds: 100,
                startMicroseconds: 200
            ),
            waitStatus: nil,
            error: nil
        )
        let terminal = SafariHandoffProcessWatchdog.Message(
            kind: .terminal,
            processGroupID: 10_002,
            waitStatus: Int32(0),
            error: nil
        )
        var exactWire = try JSONEncoder().encode(ready)
        exactWire.append(0x0A)
        var exact =
            SafariHandoffProcessSupervisor.StatusFrameDecoder()
        XCTAssertEqual(try exact.append(exactWire), [ready])
        try exact.finish()

        var wire = try JSONEncoder().encode(ready)
        wire.append(0x0A)
        wire.append(try JSONEncoder().encode(terminal))
        wire.append(0x0A)

        var decoder =
            SafariHandoffProcessSupervisor.StatusFrameDecoder()
        let split = wire.count / 2
        let first = try decoder.append(wire.prefix(split))
        let second = try decoder.append(wire.dropFirst(split))
        try decoder.finish()

        XCTAssertEqual(first + second, [ready, terminal])

        var empty =
            SafariHandoffProcessSupervisor.StatusFrameDecoder()
        XCTAssertThrowsError(try empty.append(Data([0x0A]))) {
            XCTAssertEqual(
                $0 as? SafariHandoffProcessSupervisor.StatusFrameDecoder
                    .FrameError,
                .empty
            )
        }

        var oversized =
            SafariHandoffProcessSupervisor.StatusFrameDecoder()
        XCTAssertThrowsError(
            try oversized.append(
                Data(
                    repeating: 0x41,
                    count:
                        SafariHandoffProcessWatchdog.maximumStatusBytes
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SafariHandoffProcessSupervisor.StatusFrameDecoder
                    .FrameError,
                .oversized
            )
        }

        var partial =
            SafariHandoffProcessSupervisor.StatusFrameDecoder()
        _ = try partial.append(Data("{\"kind\":\"ready\"}".utf8))
        XCTAssertThrowsError(try partial.finish()) {
            XCTAssertEqual(
                $0 as? SafariHandoffProcessSupervisor.StatusFrameDecoder
                    .FrameError,
                .partialAtEnd
            )
        }

        var malformed =
            SafariHandoffProcessSupervisor.StatusFrameDecoder()
        XCTAssertThrowsError(
            try malformed.append(Data("{\"kind\":\"unknown\"}\n".utf8))
        ) {
            XCTAssertEqual(
                $0 as? SafariHandoffProcessSupervisor.StatusFrameDecoder
                    .FrameError,
                .malformed
            )
        }
    }

    #if os(macOS)
        func testSentinelArgumentsArePrivateAndFailClosed() {
            XCTAssertFalse(
                SafariHandoffProcessSentinel.runIfRequested(arguments: [])
            )
            XCTAssertFalse(
                SafariHandoffProcessSentinel.runIfRequested(
                    arguments: ["serve"]
                )
            )
            XCTAssertEqual(
                SafariHandoffProcessSentinel.marker,
                "--safari-handoff-sentinel-v1"
            )
            XCTAssertGreaterThan(
                SafariHandoffProcessSentinel.livenessFD,
                STDERR_FILENO
            )
            XCTAssertGreaterThan(
                SafariHandoffProcessSentinel.readyFD,
                STDERR_FILENO
            )
            XCTAssertNotEqual(
                SafariHandoffProcessSentinel.livenessFD,
                SafariHandoffProcessSentinel.readyFD
            )
            XCTAssertNotEqual(
                SafariHandoffProcessSentinel.readyByte,
                0
            )
            XCTAssertNotEqual(
                SafariHandoffProcessWatchdog.sentinelLifetimeFD,
                SafariHandoffProcessSentinel.livenessFD
            )
            XCTAssertNotEqual(
                SafariHandoffProcessWatchdog.sentinelLifetimeFD,
                SafariHandoffProcessSentinel.readyFD
            )
        }

        func testPOSIXSessionWaitsForSentinelReadyBeforeWatchdogPublication()
            throws
        {
            let sourceURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/OpenBurnBarDaemon/SafariHandoffProcessSupervisor.swift"
                )
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw XCTSkip(
                    "Safari hand-off supervisor source is unavailable."
                )
            }
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let sessionStart = try XCTUnwrap(
                source.range(
                    of: "func start() throws -> Supervisor.WatchdogReady"
                )
            )
            let readyWait = try XCTUnwrap(
                source.range(
                    of: "try Self.awaitSentinelReady(",
                    range: sessionStart.lowerBound..<source.endIndex
                )
            )
            let watchdogActions = try XCTUnwrap(
                source.range(
                    of: "var actions: posix_spawn_file_actions_t?",
                    range: readyWait.lowerBound..<source.endIndex
                )
            )
            let lifetimeMapping = try XCTUnwrap(
                source.range(
                    of:
                        "SafariHandoffProcessWatchdog.sentinelLifetimeFD",
                    range: watchdogActions.lowerBound..<source.endIndex
                )
            )
            let collisionSafeCopies = try XCTUnwrap(
                source.range(
                    of: "try Self.makeSpawnMappings(rawMappings)",
                    range: lifetimeMapping.lowerBound..<source.endIndex
                )
            )
            let daemonWriterClose = try XCTUnwrap(
                source.range(
                    of:
                        "Self.closeDescriptor(&sentinelLifetime.write)",
                    range: collisionSafeCopies.lowerBound..<source.endIndex
                )
            )
            let spawnCopiesClose = try XCTUnwrap(
                source.range(
                    of: "Self.closeSpawnMappings(&mappings)",
                    range: collisionSafeCopies.lowerBound..<daemonWriterClose.lowerBound
                )
            )

            XCTAssertLessThan(
                readyWait.lowerBound,
                watchdogActions.lowerBound,
                "Sentinel READY must precede watchdog construction and publication."
            )
            XCTAssertLessThan(
                watchdogActions.lowerBound,
                lifetimeMapping.lowerBound
            )
            XCTAssertLessThan(
                lifetimeMapping.lowerBound,
                collisionSafeCopies.lowerBound,
                "Every inherited source must be duplicated above the private protocol range before posix_spawn applies ordered dup2 actions."
            )
            XCTAssertLessThan(
                collisionSafeCopies.lowerBound,
                spawnCopiesClose.lowerBound,
                "The daemon must close its spawn-only descriptor copies as soon as posix_spawn returns."
            )
            XCTAssertLessThan(
                spawnCopiesClose.lowerBound,
                daemonWriterClose.lowerBound,
                "The daemon must close its raw lifetime writer immediately after spawn so only the watchdog owns sentinel liveness during the handshake."
            )
            let spawnStatusGuard = try XCTUnwrap(
                source.range(
                    of: "guard spawnStatus == 0 else",
                    range: daemonWriterClose.lowerBound..<source.endIndex
                )
            )
            XCTAssertLessThan(
                daemonWriterClose.lowerBound,
                spawnStatusGuard.lowerBound
            )

            let sentinelSpawn = try XCTUnwrap(
                source.range(of: "private static func spawnSentinel(")
            )
            let sentinelCollisionSafeCopies = try XCTUnwrap(
                source.range(
                    of: "var mappings = try makeSpawnMappings(rawMappings)",
                    range: sentinelSpawn.lowerBound..<source.endIndex
                )
            )
            XCTAssertGreaterThan(
                sentinelCollisionSafeCopies.lowerBound,
                sentinelSpawn.lowerBound,
                "The sentinel's inherited READY and lifetime sources must also be isolated above their private target descriptors."
            )
        }

        func testSentinelLivenessClosureContainsItsExactGroup() {
            let processGroupID: pid_t = 4_199
            let probe = SafariSentinelMonitorProbe(
                processGroupID: processGroupID,
                poll: [
                    .init(result: -1, error: EINTR),
                    .init(result: 1, events: Int16(POLLHUP)),
                ]
            )

            SafariHandoffProcessSentinel.monitor(
                livenessDescriptor: 41,
                graceMicroseconds: 25,
                runtime: probe.runtime
            )

            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -processGroupID, signal: SIGTERM),
                    .init(target: -processGroupID, signal: SIGKILL),
                ]
            )
            XCTAssertEqual(probe.sleepsSnapshot(), [25])
            XCTAssertEqual(probe.pollCallCount, 2)
            XCTAssertTrue(probe.readDescriptorsSnapshot().isEmpty)
        }

        func testSentinelReadableLivenessByteStillFailsClosed() {
            let processGroupID: pid_t = 4_200
            let probe = SafariSentinelMonitorProbe(
                processGroupID: processGroupID,
                poll: [
                    .init(result: 1, events: Int16(POLLIN))
                ]
            )

            SafariHandoffProcessSentinel.monitor(
                livenessDescriptor: 42,
                graceMicroseconds: 0,
                runtime: probe.runtime
            )

            XCTAssertEqual(probe.readDescriptorsSnapshot(), [42])
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -processGroupID, signal: SIGTERM),
                    .init(target: -processGroupID, signal: SIGKILL),
                ]
            )
        }

        func testSentinelReadableLifetimeByteFailsClosedWithoutReleaseCommand() {
            let processGroupID: pid_t = 4_196
            let probe = SafariSentinelMonitorProbe(
                processGroupID: processGroupID,
                poll: [
                    .init(result: 1, events: Int16(POLLIN))
                ],
                readByte: SafariHandoffProcessSentinel.readyByte
            )

            SafariHandoffProcessSentinel.monitor(
                livenessDescriptor: 43,
                graceMicroseconds: 25,
                runtime: probe.runtime
            )

            XCTAssertEqual(probe.readDescriptorsSnapshot(), [43])
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(target: -processGroupID, signal: SIGTERM),
                    .init(target: -processGroupID, signal: SIGKILL),
                ]
            )
            XCTAssertEqual(probe.sleepsSnapshot(), [25])
        }

        func testSentinelRejectsUnsafeOrForeignProcessGroups() {
            for processGroupID in [pid_t(-1), 0, 1] {
                let probe = SafariSentinelMonitorProbe(
                    processGroupID: processGroupID
                )
                SafariHandoffProcessSentinel.contain(
                    processGroupID: processGroupID,
                    graceMicroseconds: 10,
                    runtime: probe.runtime
                )
                XCTAssertTrue(probe.signalsSnapshot().isEmpty)
                XCTAssertTrue(probe.sleepsSnapshot().isEmpty)
            }

            let probe = SafariSentinelMonitorProbe(
                processGroupID: 4_198
            )
            SafariHandoffProcessSentinel.contain(
                processGroupID: 4_197,
                graceMicroseconds: 10,
                runtime: probe.runtime
            )
            XCTAssertTrue(probe.signalsSnapshot().isEmpty)
            XCTAssertTrue(probe.sleepsSnapshot().isEmpty)
        }

        func testNaturalExitReapsChildAndContainsRemainingExactGroup() {
            let childPID: pid_t = 4_201
            let containmentIdentity = processIdentity(4_301)
            let status = Int32(12 << 8)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [
                    .init(result: childPID, status: status)
                ]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                containmentIdentity: containmentIdentity,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, status)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGTERM
                    ),
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGKILL
                    ),
                ]
            )
            XCTAssertEqual(probe.sleepsSnapshot(), [100_000])
            XCTAssertEqual(probe.waitBlockingCallCount, 0)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testLivenessEOFRequestsTermThenKillAndRetriesInterruptedReap() {
            let childPID: pid_t = 4_202
            let containmentIdentity = processIdentity(4_302)
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
                containmentIdentity: containmentIdentity,
                livenessDescriptor: 51,
                commandDescriptor: 52,
                graceNanoseconds: 10,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, killedStatus)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGTERM
                    ),
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGKILL
                    ),
                ]
            )
            XCTAssertEqual(probe.waitBlockingCallCount, 2)
            XCTAssertTrue(probe.readDescriptorsSnapshot().isEmpty)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testCommandReadRequestsImmediateExactGroupContainment() {
            let childPID: pid_t = 4_203
            let containmentIdentity = processIdentity(4_303)
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
                containmentIdentity: containmentIdentity,
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
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGTERM
                    ),
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGKILL
                    ),
                ]
            )
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testInterruptedWaitAndPollRetryBeforeNaturalReap() {
            let childPID: pid_t = 4_204
            let containmentIdentity = processIdentity(4_304)
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
                containmentIdentity: containmentIdentity,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, status)
            XCTAssertEqual(probe.waitNoHangCallCount, 3)
            XCTAssertEqual(probe.pollCallCount, 2)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGTERM
                    ),
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGKILL
                    ),
                ]
            )
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testOpenLivenessWithNoCommandDoesNotSignalBeforeNaturalExit() {
            let childPID: pid_t = 4_206
            let containmentIdentity = processIdentity(4_306)
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
                containmentIdentity: containmentIdentity,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, status)
            let events = probe.eventsSnapshot()
            let pollIndex = events.firstIndex(of: "poll")
            let reapIndex = events.firstIndex(
                of: "wait-nohang:\(childPID)"
            )
            let firstSignalIndex = events.firstIndex(
                of:
                    "signal:\(-containmentIdentity.processGroupID):\(SIGTERM)"
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
            let containmentIdentity = processIdentity(4_305)
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
                containmentIdentity: containmentIdentity,
                runtime: probe.runtime
            )

            XCTAssertEqual(observed, killedStatus)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGTERM
                    ),
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGKILL
                    ),
                ]
            )
            XCTAssertEqual(probe.waitBlockingCallCount, 2)
            XCTAssertTrue(probe.sleepsSnapshot().isEmpty)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testNonInterruptedWaitFailureNeverFabricatesSuccessfulExit() {
            let childPID: pid_t = 4_207
            let containmentIdentity = processIdentity(4_307)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [.init(result: -1, error: ECHILD)],
                waitBlocking: [.init(result: -1, error: ECHILD)]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                containmentIdentity: containmentIdentity,
                runtime: probe.runtime
            )

            XCTAssertNil(
                observed,
                "A failed wait monitor must not be decoded as exit status zero"
            )
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGTERM
                    ),
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGKILL
                    ),
                ]
            )
            XCTAssertEqual(probe.waitNoHangCallCount, 1)
            XCTAssertEqual(probe.waitBlockingCallCount, 1)
            XCTAssertTrue(probe.unexpectedCallsSnapshot().isEmpty)
        }

        func testPollAndBlockingWaitFailureRemainMonitorFailure() {
            let childPID: pid_t = 4_208
            let containmentIdentity = processIdentity(4_308)
            let probe = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                waitNoHang: [.init(result: 0)],
                waitBlocking: [.init(result: -1, error: EIO)],
                poll: [.init(result: -1, error: EIO)]
            )

            let observed = SafariHandoffProcessWatchdog.monitor(
                childPID: childPID,
                containmentIdentity: containmentIdentity,
                runtime: probe.runtime
            )

            XCTAssertNil(observed)
            XCTAssertEqual(
                probe.signalsSnapshot(),
                [
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGTERM
                    ),
                    .init(
                        target: -containmentIdentity.processGroupID,
                        signal: SIGKILL
                    ),
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

            for (childPID, identity, currentGroup) in [
                (pid_t(0), processIdentity(101), pid_t(100)),
                (pid_t(1), processIdentity(101), pid_t(100)),
                (
                    pid_t(101),
                    processIdentity(1),
                    pid_t(100)
                ),
                (
                    pid_t(101),
                    processIdentity(-2),
                    pid_t(100)
                ),
                (
                    pid_t(101),
                    processIdentity(100),
                    pid_t(100)
                ),
            ] {
                let probe = SafariWatchdogMonitorProbe(
                    currentProcessGroup: currentGroup
                )
                XCTAssertNil(
                    SafariHandoffProcessWatchdog.monitor(
                        childPID: childPID,
                        containmentIdentity: identity,
                        runtime: probe.runtime
                    )
                )
                XCTAssertFalse(
                    SafariHandoffProcessWatchdog.terminateRemainingGroup(
                        identity,
                        excludingReapedChild: true,
                        runtime: probe.runtime
                    )
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
                    containmentIdentity: processIdentity(102),
                    runtime: mismatchedProbe.runtime
                )
            )
            XCTAssertTrue(mismatchedProbe.signalsSnapshot().isEmpty)
            XCTAssertEqual(mismatchedProbe.waitNoHangCallCount, 0)
            XCTAssertTrue(mismatchedProbe.unexpectedCallsSnapshot().isEmpty)
        }

        func testIdentityMismatchNeverSignalsAndDriftSuppressesKill() {
            let identity = processIdentity(4_310)
            let mismatched = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                processMatches: [false]
            )

            XCTAssertFalse(
                SafariHandoffProcessWatchdog.terminateRemainingGroup(
                    identity,
                    excludingReapedChild: false,
                    runtime: mismatched.runtime
                )
            )
            XCTAssertTrue(mismatched.signalsSnapshot().isEmpty)

            let drifted = SafariWatchdogMonitorProbe(
                currentProcessGroup: 9_001,
                processMatches: [true, false]
            )

            XCTAssertFalse(
                SafariHandoffProcessWatchdog.terminateRemainingGroup(
                    identity,
                    excludingReapedChild: true,
                    runtime: drifted.runtime
                )
            )
            XCTAssertEqual(
                drifted.signalsSnapshot(),
                [
                    .init(
                        target: -identity.processGroupID,
                        signal: SIGTERM
                    )
                ]
            )
            XCTAssertEqual(drifted.sleepsSnapshot(), [100_000])
        }
    #endif

    private func processIdentity(
        _ processID: Int32
    ) -> SafariHandoffProcessSupervisor.ProcessIdentity {
        .init(
            processID: processID,
            processGroupID: processID,
            startSeconds: 100,
            startMicroseconds: 200
        )
    }
}

#if os(macOS)
    private final class SafariSentinelMonitorProbe: @unchecked Sendable {
        struct PollStep {
            let result: Int32
            let events: Int16
            let error: Int32

            init(
                result: Int32,
                events: Int16 = 0,
                error: Int32 = 0
            ) {
                self.result = result
                self.events = events
                self.error = error
            }
        }

        struct SignalRecord: Equatable {
            let target: pid_t
            let signal: Int32
        }

        private let lock = NSLock()
        private let processGroupID: pid_t
        private var pollSteps: [PollStep]
        private var lastError: Int32 = 0
        private var signals: [SignalRecord] = []
        private var sleeps: [useconds_t] = []
        private var readDescriptors: [Int32] = []
        private var _pollCallCount = 0
        private let nextReadByte: UInt8

        init(
            processGroupID: pid_t,
            poll: [PollStep] = [],
            readByte: UInt8 = 1
        ) {
            self.processGroupID = processGroupID
            pollSteps = poll
            nextReadByte = readByte
        }

        var runtime: SafariHandoffProcessSentinel.Runtime {
            .init(
                pollEvents: { [self] descriptor, _ in
                    locked {
                        _pollCallCount += 1
                        let step = pollSteps.isEmpty
                            ? PollStep(result: 0)
                            : pollSteps.removeFirst()
                        descriptor.revents = step.events
                        lastError = step.error
                        return step.result
                    }
                },
                readByte: { [self] descriptor, byte in
                    locked {
                        readDescriptors.append(descriptor)
                        byte.pointee = nextReadByte
                        lastError = 0
                        return 1
                    }
                },
                signal: { [self] target, signal in
                    locked {
                        signals.append(
                            SignalRecord(
                                target: target,
                                signal: signal
                            )
                        )
                        return 0
                    }
                },
                sleepMicroseconds: { [self] duration in
                    locked {
                        sleeps.append(duration)
                    }
                },
                currentErrno: { [self] in
                    locked { lastError }
                },
                currentProcessGroup: { [self] in
                    processGroupID
                }
            )
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

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

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
        private var processMatchSteps: [Bool]

        init(
            currentProcessGroup: pid_t,
            waitNoHang: [WaitStep] = [],
            waitBlocking: [WaitStep] = [],
            poll: [PollStep] = [],
            uptimeNanoseconds: [UInt64] = [0],
            processMatches: [Bool] = []
        ) {
            processGroup = currentProcessGroup
            waitNoHangSteps = waitNoHang
            waitBlockingSteps = waitBlocking
            pollSteps = poll
            uptimes = uptimeNanoseconds
            lastUptime = uptimeNanoseconds.last ?? 0
            processMatchSteps = processMatches
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
                currentProcessGroup: { [self] in processGroup },
                processMatches: { [self] identity in
                    processMatches(identity)
                }
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

        private func processMatches(
            _ identity: SafariHandoffProcessSupervisor.ProcessIdentity
        ) -> Bool {
            locked {
                events.append(
                    "identity:\(identity.processID):\(identity.startSeconds):\(identity.startMicroseconds)"
                )
                guard processMatchSteps.isEmpty == false else {
                    return identity.processID > 1
                        && identity.processID == identity.processGroupID
                        && identity.processGroupID != processGroup
                }
                return processMatchSteps.removeFirst()
            }
        }

        @discardableResult
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
#endif
