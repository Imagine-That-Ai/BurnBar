import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBarCore

final class HermesRatchetCryptoTests: XCTestCase {
    func test_roundTrip_andReply_performDHRatchet() throws {
        var alice = try makeInitiator()
        var bob = try makeResponder()
        let ad = Data("uid=u1|client=c1|destination=home".utf8)

        let first = try HermesRatchetCrypto.encrypt(plaintext: Data("hello".utf8), state: &alice, associatedData: ad)
        XCTAssertEqual(first.header.messageNumber, 0)
        XCTAssertEqual(first.header.previousChainLength, 0)
        XCTAssertEqual(first.header.epoch, 0)

        let opened = try HermesRatchetCrypto.decrypt(first, state: &bob, associatedData: ad)
        XCTAssertEqual(String(data: opened, encoding: .utf8), "hello")
        XCTAssertEqual(bob.epoch, 1)
        XCTAssertEqual(bob.receiveMessageNumber, 1)
        XCTAssertEqual(bob.sendMessageNumber, 0)

        let reply = try HermesRatchetCrypto.encrypt(plaintext: Data("ack".utf8), state: &bob, associatedData: ad)
        XCTAssertEqual(reply.header.messageNumber, 0)
        XCTAssertEqual(reply.header.previousChainLength, 0)
        XCTAssertEqual(reply.header.epoch, 1)

        let openedReply = try HermesRatchetCrypto.decrypt(reply, state: &alice, associatedData: ad)
        XCTAssertEqual(String(data: openedReply, encoding: .utf8), "ack")
        XCTAssertEqual(alice.epoch, 1)
    }

    func test_outOfOrderReceive_usesBoundedSkippedKeys() throws {
        var alice = try makeInitiator()
        var bob = try makeResponder(maxSkip: 4)
        let one = try HermesRatchetCrypto.encrypt(plaintext: Data("1".utf8), state: &alice)
        let two = try HermesRatchetCrypto.encrypt(plaintext: Data("2".utf8), state: &alice)

        let openedTwo = try HermesRatchetCrypto.decrypt(two, state: &bob)
        XCTAssertEqual(String(data: openedTwo, encoding: .utf8), "2")
        XCTAssertEqual(bob.skippedMessageKeys.count, 1)

        let openedOne = try HermesRatchetCrypto.decrypt(one, state: &bob)
        XCTAssertEqual(String(data: openedOne, encoding: .utf8), "1")
        XCTAssertEqual(bob.skippedMessageKeys.count, 0)
    }

    func test_associatedDataTamperFailsAuthentication() throws {
        var alice = try makeInitiator()
        var bob = try makeResponder()
        let envelope = try HermesRatchetCrypto.encrypt(
            plaintext: Data("secret".utf8),
            state: &alice,
            associatedData: Data("destination=home".utf8)
        )

        XCTAssertThrowsError(
            try HermesRatchetCrypto.decrypt(envelope, state: &bob, associatedData: Data("destination=other".utf8))
        ) { error in
            XCTAssertEqual(error as? HermesRatchetError, .authenticationFailed)
        }
    }

    func test_replayAfterSuccessfulOpenFails() throws {
        var alice = try makeInitiator()
        var bob = try makeResponder()
        let envelope = try HermesRatchetCrypto.encrypt(plaintext: Data("once".utf8), state: &alice)
        _ = try HermesRatchetCrypto.decrypt(envelope, state: &bob)

        XCTAssertThrowsError(try HermesRatchetCrypto.decrypt(envelope, state: &bob)) { error in
            XCTAssertEqual(error as? HermesRatchetError, .authenticationFailed)
        }
    }

    func test_skipLimitPreventsUnboundedSkippedKeyStorage() throws {
        var alice = try makeInitiator()
        var bob = try makeResponder(maxSkip: 1)
        _ = try HermesRatchetCrypto.encrypt(plaintext: Data("0".utf8), state: &alice)
        _ = try HermesRatchetCrypto.encrypt(plaintext: Data("1".utf8), state: &alice)
        let third = try HermesRatchetCrypto.encrypt(plaintext: Data("2".utf8), state: &alice)

        XCTAssertThrowsError(try HermesRatchetCrypto.decrypt(third, state: &bob)) { error in
            XCTAssertEqual(error as? HermesRatchetError, .tooManySkippedKeys)
        }
    }

    func test_headerTamperFailsBeforeDecrypt() throws {
        var alice = try makeInitiator()
        var bob = try makeResponder()
        let envelope = try HermesRatchetCrypto.encrypt(plaintext: Data("hello".utf8), state: &alice)
        let badHeader = HermesRatchetHeader(
            sessionID: "wrong-session",
            senderDeviceID: envelope.header.senderDeviceID,
            receiverDeviceID: envelope.header.receiverDeviceID,
            ratchetPublicKeyBase64: envelope.header.ratchetPublicKeyBase64,
            previousChainLength: envelope.header.previousChainLength,
            messageNumber: envelope.header.messageNumber,
            epoch: envelope.header.epoch
        )
        let tampered = HermesRatchetEnvelope(header: badHeader, ciphertextBase64: envelope.ciphertextBase64)

        XCTAssertThrowsError(try HermesRatchetCrypto.decrypt(tampered, state: &bob)) { error in
            XCTAssertEqual(error as? HermesRatchetError, .invalidEnvelope)
        }
    }

    func test_pythonKnownVector_decryptsAndMatchesKDF() throws {
        let sharedSecret = try Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let initiatorInitial = fixedKeyPair(
            privateKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM=",
            publicKeyBase64: "BF7L5NGmMwpEyPfvlR1L8WXmxrch762phftBZhvG5/1shzRkDEmY/343SwbOGmSi7NgqsDY4T7g9mnmxJ6J9UDI="
        )
        let responderInitial = fixedKeyPair(
            privateKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAU=",
            publicKeyBase64: "BFFZC3pRUUDS14TIVghmj9/vjIL9H1vlJCFVSg3D0DPt4MF9qJBKcn2K4b82v4p5Jg0BLwDU2AiI0dC7RP2hbaQ="
        )
        let initiator = try HermesRatchetCrypto.initiatorState(
            sessionID: "session-alpha",
            localDeviceID: "agent-device",
            remoteDeviceID: "phone-device",
            sharedSecret: sharedSecret,
            remoteInitialRatchetPublicKeyBase64: responderInitial.publicKeyBase64,
            localInitialRatchetKeyPair: initiatorInitial
        )
        XCTAssertEqual(initiator.rootKeyBase64, "kRRkcvhOvnCbQllS0YhJ6o3JesOS8deAaGWc2lRLizc=")

        var responder = try HermesRatchetCrypto.responderState(
            sessionID: "session-alpha",
            localDeviceID: "phone-device",
            remoteDeviceID: "agent-device",
            sharedSecret: sharedSecret,
            localInitialRatchetKeyPair: responderInitial
        )
        let envelope = HermesRatchetEnvelope(
            header: HermesRatchetHeader(
                sessionID: "session-alpha",
                senderDeviceID: "agent-device",
                receiverDeviceID: "phone-device",
                ratchetPublicKeyBase64: initiatorInitial.publicKeyBase64,
                previousChainLength: 0,
                messageNumber: 0,
                epoch: 0
            ),
            ciphertextBase64: "AAECAwQFBgcICQoLtJG1Ei/8I6FXnVOkbdEygdSRtj69G1Aais9OzfKL9Vhx"
        )

        let opened = try HermesRatchetCrypto.decrypt(
            envelope,
            state: &responder,
            associatedData: Data("gateway-message:session-alpha".utf8)
        )
        XCTAssertEqual(String(data: opened, encoding: .utf8), "hello from python")
        XCTAssertEqual(responder.receivingChainKeyBase64, "yIl48A/RFS5oRS6PiDlDWZt+m8+NNjoV5Mfrpc5+w0s=")
    }

    private func makeInitiator(maxSkip: Int = HermesRatchetCrypto.defaultMaxSkip) throws -> HermesRatchetSessionState {
        let sharedSecret = Data(repeating: 7, count: 32)
        let bobInitial = responderInitialKeyPair
        return try HermesRatchetCrypto.initiatorState(
            sessionID: "session-1",
            localDeviceID: "alice",
            remoteDeviceID: "bob",
            sharedSecret: sharedSecret,
            remoteInitialRatchetPublicKeyBase64: bobInitial.publicKeyBase64,
            maxSkip: maxSkip
        )
    }

    private func makeResponder(maxSkip: Int = HermesRatchetCrypto.defaultMaxSkip) throws -> HermesRatchetSessionState {
        let sharedSecret = Data(repeating: 7, count: 32)
        return try HermesRatchetCrypto.responderState(
            sessionID: "session-1",
            localDeviceID: "bob",
            remoteDeviceID: "alice",
            sharedSecret: sharedSecret,
            localInitialRatchetKeyPair: responderInitialKeyPair,
            maxSkip: maxSkip
        )
    }

    private var responderInitialKeyPair: HermesRatchetKeyPair {
        if let cached = Self.cachedResponderInitialKeyPair { return cached }
        let created = HermesRatchetCrypto.generateKeyPair()
        Self.cachedResponderInitialKeyPair = created
        return created
    }

    private func fixedKeyPair(privateKeyBase64: String, publicKeyBase64: String) -> HermesRatchetKeyPair {
        HermesRatchetKeyPair(privateKeyBase64: privateKeyBase64, publicKeyBase64: publicKeyBase64)
    }

    private static var cachedResponderInitialKeyPair: HermesRatchetKeyPair?
}

private extension Data {
    init(hex: String) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard next <= hex.endIndex,
                  let byte = UInt8(hex[index..<next], radix: 16) else {
                throw HermesRatchetError.invalidBase64("hex")
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
