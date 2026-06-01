import Foundation
import LocalAuthentication
import OpenBurnBarComputerUseCore

enum DesktopGrantLocalAuthenticator {
    enum AuthError: Error {
        case unavailable
        case failed
    }

    static func authenticateIfNeeded(for preset: AgentPermissionPreset) async throws -> Bool {
        guard preset.requiresLocalAuthentication else { return false }
        return try await authenticate(reason: "Allow \(preset.title) desktop permissions for this agent thread.")
    }

    static func authenticateIfNeeded(
        capabilities: Set<AgentDesktopCapability>,
        trustMode: ComputerUseTrustMode,
        promptName: String
    ) async throws -> Bool {
        guard AgentDesktopCapability.requiresLocalAuthentication(
            capabilities: capabilities,
            trustMode: trustMode
        ) else { return false }
        return try await authenticate(reason: "Allow \(promptName) desktop permissions for this agent thread.")
    }

    private static func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw AuthError.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                if success {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(throwing: AuthError.failed)
                }
            }
        }
    }
}
