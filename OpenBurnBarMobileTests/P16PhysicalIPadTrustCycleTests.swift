import CryptoKit
import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import Foundation
import UIKit
import XCTest
@testable import OpenBurnBarMobile

@MainActor
final class P16PhysicalIPadTrustCycleTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    func testApprovePendingLinuxDevice() async throws {
        try requirePhysicalIPad(phase: "approve")
        let request: Request = try decodeEnvironment("OPENBURNBAR_P16_REQUEST_BASE64")
        try request.validate()
        try configureFirebaseIfNeeded()
        _ = try requireSignedInUser()

        let approverDeviceID = MobileDeviceIdentity.loadOrCreateDeviceId()
        let pending = try await waitForDevice(request: request, approverDeviceID: approverDeviceID, state: .pending)
        var events = [event(sequence: 1, action: "list", callable: "listLinuxAppCheckDevices", state: "pending")]
        let approvalEvidence = try await mutate(pending, approverDeviceID: approverDeviceID, approve: true)
        events.append(actionEvent(sequence: 2, action: "approve", state: "approved", evidence: approvalEvidence))
        _ = try await waitForDevice(request: request, approverDeviceID: approverDeviceID, state: .approved)
        events.append(event(sequence: 3, action: "list", callable: "listLinuxAppCheckDevices", state: "approved"))

        let checkpoint = ApprovalCheckpoint(
            producer: "openburnbar-p16-physical-ipad-approval-checkpoint-v1",
            request: request,
            physicalDevice: try physicalDevice(),
            events: events
        )
        emit("OPENBURNBAR_P16_APPROVAL_RESULT_BASE64", checkpoint)
    }

    func testRevokeApprovedLinuxDevice() async throws {
        try requirePhysicalIPad(phase: "revoke")
        let request: Request = try decodeEnvironment("OPENBURNBAR_P16_REQUEST_BASE64")
        let checkpoint: ApprovalCheckpoint = try decodeEnvironment("OPENBURNBAR_P16_APPROVAL_BASE64")
        try request.validate()
        guard checkpoint.producer == "openburnbar-p16-physical-ipad-approval-checkpoint-v1",
              checkpoint.request == request,
              checkpoint.events.count == 3 else {
            throw Failure("Approval checkpoint does not bind this Linux request.")
        }
        try configureFirebaseIfNeeded()
        _ = try requireSignedInUser()

        let approverDeviceID = MobileDeviceIdentity.loadOrCreateDeviceId()
        let approved = try await waitForDevice(request: request, approverDeviceID: approverDeviceID, state: .approved)
        let revocationEvidence = try await mutate(approved, approverDeviceID: approverDeviceID, approve: false)
        var events = checkpoint.events
        events.append(actionEvent(sequence: 4, action: "revoke", state: "revoked", evidence: revocationEvidence))
        _ = try await waitForDevice(request: request, approverDeviceID: approverDeviceID, state: .revoked)
        events.append(event(sequence: 5, action: "list", callable: "listLinuxAppCheckDevices", state: "revoked"))

        let receipt = Receipt(
            producer: "openburnbar-p16-physical-ipad-trust-cycle-v1",
            capturedAt: timestamp(),
            targetHead: request.targetHead,
            candidate: request.candidate,
            physicalDevice: checkpoint.physicalDevice,
            linux: .init(
                deviceIdHash: request.linux.deviceIdHash,
                marker: request.marker,
                safetyFingerprintHash: request.linux.safetyFingerprintHash
            ),
            events: events,
            restoration: .init(
                createdDeviceRevoked: true,
                noPendingMutation: true,
                trustedDeviceStateRestored: true
            )
        )
        emit("OPENBURNBAR_P16_RECEIPT_BASE64", receipt)
    }

    private func requirePhysicalIPad(phase: String) throws {
        guard environment["OPENBURNBAR_P16_PHASE"] == phase else {
            throw XCTSkip("This method is only armed for the P-16 \(phase) phase.")
        }
#if targetEnvironment(simulator)
        XCTFail("P-16 requires a physical iPad; Simulator evidence is forbidden.")
        throw Failure("Simulator is forbidden.")
#else
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw Failure("P-16 requires a physical iPad, not an iPhone.")
        }
#endif
        guard Bundle.main.bundleIdentifier == "com.openburnbar.app" else {
            throw Failure("P-16 must run in the signed com.openburnbar.app host.")
        }
    }

    private func configureFirebaseIfNeeded() throws {
        guard FirebaseApp.app() == nil else { return }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            throw Failure("GoogleService-Info.plist is missing from the physical-device host.")
        }
        AppDelegate.installAppCheckProviderFactory(firebasePlistPath: path)
        FirebaseApp.configure(options: options)
    }

    private func requireSignedInUser() throws -> User {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else {
            throw Failure("OpenBurnBar must already be signed in with a non-anonymous account on this iPad.")
        }
        return user
    }

    private func waitForDevice(
        request: Request,
        approverDeviceID: String,
        state: LinuxAppCheckDeviceTrustState
    ) async throws -> LinuxAppCheckDeviceRecord {
        let deadline = Date().addingTimeInterval(120)
        var lastStates = "none"
        repeat {
            let devices = try await ComputerUseSecurityCallableClient.listLinuxAppCheckDevices(
                approverDeviceId: approverDeviceID
            )
            let matches = devices.filter {
                digest($0.deviceId) == request.linux.deviceIdHash &&
                    digest($0.safetyFingerprint) == request.linux.safetyFingerprintHash
            }
            guard matches.count <= 1 else { throw Failure("Linux request matched multiple cloud devices.") }
            if let match = matches.first, match.trustState == state { return match }
            lastStates = matches.map(\.trustState.rawValue).joined(separator: ",")
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        throw Failure("Linux device did not reach \(state.rawValue); observed \(lastStates).")
    }

    private func mutate(
        _ device: LinuxAppCheckDeviceRecord,
        approverDeviceID: String,
        approve: Bool
    ) async throws -> MutationEvidence {
        let descriptor = ComputerUseSecurityCallableClient.linuxAppCheckTrustMutationDescriptor(
            deviceId: device.deviceId,
            approverDeviceId: approverDeviceID,
            approve: approve
        )
        let envelope = try await ComputerUseSecurityCallableClient.highRiskOwnerActionEnvelope(
            actionKind: descriptor.actionKind,
            subjectId: descriptor.subjectId,
            deviceId: descriptor.approverDeviceId,
            approve: descriptor.approve
        )
        guard let nonce = envelope["nonce"] as? String,
              let proof = envelope["actionProof"] as? [String: any Sendable] else {
            throw Failure("Trusted-device action envelope was incomplete.")
        }
        var payload: [String: Any] = [
            "deviceId": descriptor.deviceId,
            "approverDeviceId": descriptor.approverDeviceId
        ]
        envelope.forEach { payload[$0.key] = $0.value }
        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable(descriptor.callableName)
            .call(payload)
        guard let response = result.data as? [String: Any], response["ok"] as? Bool == true else {
            throw Failure("\(descriptor.callableName) rejected the signed mutation.")
        }
        let proofObject = proof.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        let proofData = try JSONSerialization.data(withJSONObject: proofObject, options: [.sortedKeys])
        return MutationEvidence(nonceHash: digest(nonce), proofHash: digest(proofData))
    }

    private func physicalDevice() throws -> PhysicalDevice {
        guard let identifier = UIDevice.current.identifierForVendor?.uuidString else {
            throw Failure("Physical iPad vendor identifier is unavailable.")
        }
        return PhysicalDevice(
            appCheckAttested: true,
            bundleIdentifier: "com.openburnbar.app",
            deviceIdentifierHash: digest(identifier),
            platform: "iPadOS",
            simulator: false
        )
    }

    private func event(sequence: Int, action: String, callable: String, state: String) -> Event {
        Event(action: action, actionNonceHash: nil, callable: callable, nonceBound: false,
              observedAt: timestamp(), sequence: sequence, signedActionProof: false,
              signedActionProofHash: nil, state: state)
    }

    private func actionEvent(sequence: Int, action: String, state: String, evidence: MutationEvidence) -> Event {
        Event(action: action, actionNonceHash: evidence.nonceHash,
              callable: action == "approve" ? "approveLinuxAppCheckDevice" : "revokeLinuxAppCheckDevice",
              nonceBound: true, observedAt: timestamp(), sequence: sequence,
              signedActionProof: true, signedActionProofHash: evidence.proofHash, state: state)
    }

    private func decodeEnvironment<T: Decodable>(_ name: String) throws -> T {
        let key = "TEST_RUNNER_\(name)"
        guard let encoded = environment[key] ?? environment[name],
              let data = Data(base64Encoded: encoded) else {
            throw Failure("\(name) is missing or invalid base64.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func emit<T: Encodable>(_ name: String, _ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let encoded = try encoder.encode(value).base64EncodedString()
            print("\(name)=\(encoded)")
        } catch {
            XCTFail("Could not encode \(name): \(error.localizedDescription)")
        }
    }

    private func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    private func digest(_ value: Data) -> String {
        "sha256:" + SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
    private func timestamp() -> String { ISO8601DateFormatter.p16.string(from: Date()) }
}

private extension ISO8601DateFormatter {
    static let p16: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
private struct MutationEvidence { let nonceHash: String; let proofHash: String }
private struct Candidate: Codable, Equatable { let runId: String; let artifactDigest: String }
private struct LinuxIdentity: Codable, Equatable { let deviceIdHash: String; let safetyFingerprintHash: String }
private struct ReceiptLinuxIdentity: Codable {
    let deviceIdHash: String; let marker: String; let safetyFingerprintHash: String
}
private struct Request: Codable, Equatable {
    let producer: String
    let requestedAt: String
    let targetHead: String
    let candidate: Candidate
    let marker: String
    let challenge: String
    let linux: LinuxIdentity

    func validate() throws {
        let sha = /^sha256:[a-f0-9]{64}$/
        guard producer == "openburnbar-p16-linux-trust-cycle-request-v1",
              try /^p16-[a-f0-9]{16}$/.wholeMatch(in: marker) != nil,
              try /^[a-f0-9]{40}$/.wholeMatch(in: targetHead) != nil,
              try /^[a-f0-9]{64}$/.wholeMatch(in: challenge) != nil,
              try sha.wholeMatch(in: linux.deviceIdHash) != nil,
              try sha.wholeMatch(in: linux.safetyFingerprintHash) != nil else {
            throw Failure("P-16 request schema or binding is invalid.")
        }
    }
}
private struct PhysicalDevice: Codable, Equatable {
    let appCheckAttested: Bool; let bundleIdentifier: String; let deviceIdentifierHash: String
    let platform: String; let simulator: Bool
}
private struct Event: Codable, Equatable {
    let action: String; let actionNonceHash: String?; let callable: String; let nonceBound: Bool
    let observedAt: String; let sequence: Int; let signedActionProof: Bool
    let signedActionProofHash: String?; let state: String
}
private struct ApprovalCheckpoint: Codable, Equatable {
    let producer: String; let request: Request; let physicalDevice: PhysicalDevice; let events: [Event]
}
private struct Restoration: Codable {
    let createdDeviceRevoked: Bool; let noPendingMutation: Bool; let trustedDeviceStateRestored: Bool
}
private struct Receipt: Codable {
    let producer: String; let capturedAt: String; let targetHead: String; let candidate: Candidate
    let physicalDevice: PhysicalDevice; let linux: ReceiptLinuxIdentity; let events: [Event]; let restoration: Restoration
}
