import XCTest
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class ControlSealSealingSinkTests: XCTestCase {
    private actor CapturedFrames {
        private(set) var frames: [HermesRealtimeRelayFrame] = []
        func append(_ frame: HermesRealtimeRelayFrame) {
            frames.append(frame)
        }
    }

    func testSealingSinkReplacesControlPayloadWithSealedShell() async throws {
        let key = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 7, count: 32),
            salt: Data("conn-sink".utf8)
        )
        let session = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "iphone-sink",
                senderPeerNodeId: "iphone-sink",
                senderKeyId: "relay-v3-sink",
                senderCounter: 1,
                relayKeyVersion: 3
            ),
            key: key,
            controllerPeerNodeId: "ios-phone-sinktest000000000000000000"
        )
        let captured = CapturedFrames()
        let sink = ControlSealSessionEstablisher.sealingFrameSink(
            { frame in await captured.append(frame) },
            session: session
        )

        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.25,
            normalizedY: 0.75,
            normalizedX2: nil,
            normalizedY2: nil,
            text: "sealed text payload",
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: "intent-sink-1",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "ios-phone-sinktest000000000000000000",
                counter: 3,
                timestamp: Date(),
                intentHashBlake3: String(repeating: "cd", count: 32),
                signatureEd25519: Data(repeating: 2, count: 64).base64EncodedString()
            )
        )
        intent.clientIntentId = "intent-sink-1"
        try await sink(HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-sink",
            connectionId: "conn-sink",
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                inputIntent: intent
            )
        ))

        let frames = await captured.frames
        XCTAssertEqual(frames.count, 1)
        let control = try XCTUnwrap(frames.first?.control)
        // Routing shell only — the intent (and its text) never ride plaintext.
        XCTAssertEqual(control.streamClass, "control.input")
        XCTAssertNil(control.inputIntent)
        let sealed = try XCTUnwrap(control.sealedFrameBase64)
        XCTAssertFalse(sealed.contains("sealed text payload"))

        let opened = try ControlFrameSealSession.openPayload(
            control,
            key: key,
            peerNodeId: "ios-phone-sinktest000000000000000000",
            frameType: HermesRealtimeRelayFrameType.controlInputIntent.rawValue
        )
        XCTAssertEqual(opened.inputIntent?.clientIntentId, "intent-sink-1")
        XCTAssertEqual(opened.inputIntent?.text, "sealed text payload")
        XCTAssertEqual(opened.inputIntent?.authority.counter, 3)
    }

    func testSealingSinkPassesNonControlFramesUntouched() async throws {
        let key = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 9, count: 32),
            salt: Data("conn-passthrough".utf8)
        )
        let session = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "d",
                senderPeerNodeId: "d",
                senderKeyId: "k",
                senderCounter: 1,
                relayKeyVersion: 3
            ),
            key: key,
            controllerPeerNodeId: "ios-phone-passthrough0000000000000000"
        )
        let captured = CapturedFrames()
        let sink = ControlSealSessionEstablisher.sealingFrameSink(
            { frame in await captured.append(frame) },
            session: session
        )
        try await sink(HermesRealtimeRelayFrame(type: .ping, uid: "u", connectionId: "c"))
        let frames = await captured.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames.first?.control)
    }

    func testUnregisteredFreshControlSealSessionDoesNotReplaceActiveSession() async throws {
        let oldKey = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 6, count: 32),
            salt: Data("conn-pending".utf8)
        )
        let freshKey = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 7, count: 32),
            salt: Data("conn-pending".utf8)
        )
        let peerNodeId = "ios-phone-pending000000000000000000"
        let oldSession = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "iphone-pending",
                senderPeerNodeId: "iphone-pending",
                senderKeyId: "relay-v3-pending-old",
                senderCounter: 1,
                relayKeyVersion: 3
            ),
            key: oldKey,
            controllerPeerNodeId: peerNodeId
        )
        let freshSession = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "iphone-pending",
                senderPeerNodeId: "iphone-pending",
                senderKeyId: "relay-v3-pending-new",
                senderCounter: 2,
                relayKeyVersion: 3
            ),
            key: freshKey,
            controllerPeerNodeId: peerNodeId
        )
        await MainActor.run {
            ControlSealSessionEstablisher.clearForTests()
            ControlSealSessionEstablisher.register(oldSession, connectionID: "conn-pending")
        }

        let captured = CapturedFrames()
        let sink = ControlSealSessionEstablisher.sealingFrameSink(
            { frame in await captured.append(frame) },
            session: freshSession
        )
        try await sink(HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-pending",
            connectionId: "conn-pending",
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                inputIntent: HermesRealtimeRelayInputIntent(
                    kind: .tap,
                    displayId: nil,
                    normalizedX: 0.3,
                    normalizedY: 0.4,
                    normalizedX2: nil,
                    normalizedY2: nil,
                    text: nil,
                    key: nil,
                    modifiers: nil,
                    mouseButton: nil,
                    clientIntentId: "intent-pending",
                    authority: HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId: peerNodeId,
                        counter: 10,
                        timestamp: Date(),
                        intentHashBlake3: String(repeating: "ab", count: 32),
                        signatureEd25519: Data(repeating: 4, count: 64).base64EncodedString()
                    )
                )
            )
        ))

        let frames = await captured.frames
        let control = try XCTUnwrap(frames.first?.control)
        let opened = try ControlFrameSealSession.openPayload(
            control,
            key: oldKey,
            peerNodeId: peerNodeId,
            frameType: HermesRealtimeRelayFrameType.controlInputIntent.rawValue
        )
        XCTAssertEqual(opened.inputIntent?.clientIntentId, "intent-pending")
        XCTAssertThrowsError(try ControlFrameSealSession.openPayload(
            control,
            key: freshKey,
            peerNodeId: peerNodeId,
            frameType: HermesRealtimeRelayFrameType.controlInputIntent.rawValue
        ))
        await MainActor.run {
            ControlSealSessionEstablisher.clearForTests()
        }
    }

    func testSealingSinkUsesLatestRegisteredSessionForConnection() async throws {
        let oldKey = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 4, count: 32),
            salt: Data("conn-refresh".utf8)
        )
        let freshKey = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 5, count: 32),
            salt: Data("conn-refresh".utf8)
        )
        let oldSession = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "iphone-refresh",
                senderPeerNodeId: "iphone-refresh",
                senderKeyId: "relay-v3-refresh-old",
                senderCounter: 1,
                relayKeyVersion: 3
            ),
            key: oldKey,
            controllerPeerNodeId: "ios-phone-refresh0000000000000000000"
        )
        let freshSession = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "iphone-refresh",
                senderPeerNodeId: "iphone-refresh",
                senderKeyId: "relay-v3-refresh-new",
                senderCounter: 2,
                relayKeyVersion: 3
            ),
            key: freshKey,
            controllerPeerNodeId: "ios-phone-refresh0000000000000000000"
        )
        await MainActor.run {
            ControlSealSessionEstablisher.clearForTests()
            ControlSealSessionEstablisher.register(oldSession, connectionID: "conn-refresh")
        }
        let captured = CapturedFrames()
        let sink = ControlSealSessionEstablisher.sealingFrameSink(
            { frame in await captured.append(frame) },
            session: oldSession
        )
        await MainActor.run {
            ControlSealSessionEstablisher.register(freshSession, connectionID: "conn-refresh")
        }

        try await sink(HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-refresh",
            connectionId: "conn-refresh",
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                inputIntent: HermesRealtimeRelayInputIntent(
                    kind: .tap,
                    displayId: nil,
                    normalizedX: 0.1,
                    normalizedY: 0.2,
                    normalizedX2: nil,
                    normalizedY2: nil,
                    text: nil,
                    key: nil,
                    modifiers: nil,
                    mouseButton: nil,
                    clientIntentId: "intent-refresh",
                    authority: HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId: "ios-phone-refresh0000000000000000000",
                        counter: 9,
                        timestamp: Date(),
                        intentHashBlake3: String(repeating: "ef", count: 32),
                        signatureEd25519: Data(repeating: 3, count: 64).base64EncodedString()
                    )
                )
            )
        ))

        let frames = await captured.frames
        let control = try XCTUnwrap(frames.first?.control)
        XCTAssertThrowsError(try ControlFrameSealSession.openPayload(
            control,
            key: oldKey,
            peerNodeId: "ios-phone-refresh0000000000000000000",
            frameType: HermesRealtimeRelayFrameType.controlInputIntent.rawValue
        ))
        let opened = try ControlFrameSealSession.openPayload(
            control,
            key: freshKey,
            peerNodeId: "ios-phone-refresh0000000000000000000",
            frameType: HermesRealtimeRelayFrameType.controlInputIntent.rawValue
        )
        XCTAssertEqual(opened.inputIntent?.clientIntentId, "intent-refresh")
        await MainActor.run {
            ControlSealSessionEstablisher.clearForTests()
        }
    }

    func testUnregisterClearsStaleControlSealSessionBeforeReconnect() async throws {
        let oldKey = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 10, count: 32),
            salt: Data("conn-reconnect".utf8)
        )
        let freshKey = ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: Data(repeating: 11, count: 32),
            salt: Data("conn-reconnect".utf8)
        )
        let peerNodeId = "ios-phone-reconnect00000000000000000"
        let oldSession = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "iphone-reconnect",
                senderPeerNodeId: "iphone-reconnect",
                senderKeyId: "relay-v3-reconnect-old",
                senderCounter: 1,
                relayKeyVersion: 3
            ),
            key: oldKey,
            controllerPeerNodeId: peerNodeId
        )
        let freshSession = ControlSealSessionEstablisher.Session(
            envelope: HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64: "",
                wrappedKeyBase64: "",
                senderDeviceId: "iphone-reconnect",
                senderPeerNodeId: "iphone-reconnect",
                senderKeyId: "relay-v3-reconnect-new",
                senderCounter: 2,
                relayKeyVersion: 3
            ),
            key: freshKey,
            controllerPeerNodeId: peerNodeId
        )
        await MainActor.run {
            ControlSealSessionEstablisher.clearForTests()
            ControlSealSessionEstablisher.register(oldSession, connectionID: "conn-reconnect")
            ControlSealSessionEstablisher.unregister(connectionID: "conn-reconnect")
        }

        let captured = CapturedFrames()
        let sink = ControlSealSessionEstablisher.sealingFrameSink(
            { frame in await captured.append(frame) },
            session: freshSession
        )
        try await sink(HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-reconnect",
            connectionId: "conn-reconnect",
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                inputIntent: HermesRealtimeRelayInputIntent(
                    kind: .tap,
                    displayId: nil,
                    normalizedX: 0.6,
                    normalizedY: 0.7,
                    normalizedX2: nil,
                    normalizedY2: nil,
                    text: nil,
                    key: nil,
                    modifiers: nil,
                    mouseButton: nil,
                    clientIntentId: "intent-reconnect",
                    authority: HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId: peerNodeId,
                        counter: 12,
                        timestamp: Date(),
                        intentHashBlake3: String(repeating: "12", count: 32),
                        signatureEd25519: Data(repeating: 5, count: 64).base64EncodedString()
                    )
                )
            )
        ))

        let frames = await captured.frames
        let control = try XCTUnwrap(frames.first?.control)
        XCTAssertThrowsError(try ControlFrameSealSession.openPayload(
            control,
            key: oldKey,
            peerNodeId: peerNodeId,
            frameType: HermesRealtimeRelayFrameType.controlInputIntent.rawValue
        ))
        let opened = try ControlFrameSealSession.openPayload(
            control,
            key: freshKey,
            peerNodeId: peerNodeId,
            frameType: HermesRealtimeRelayFrameType.controlInputIntent.rawValue
        )
        XCTAssertEqual(opened.inputIntent?.clientIntentId, "intent-reconnect")
        await MainActor.run {
            ControlSealSessionEstablisher.clearForTests()
        }
    }
}
