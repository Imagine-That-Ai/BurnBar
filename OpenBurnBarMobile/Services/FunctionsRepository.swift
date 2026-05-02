import Foundation
import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Functions Repository

@MainActor
final class FunctionsRepository {
    static let shared = FunctionsRepository()

    private let functions = Functions.functions()

    func connectProviderCredential(provider: String, credential: String, kind: CredentialKind) async throws -> ProviderConnectionDoc {
        let callable = functions.httpsCallable("connectProviderCredential")
        let result = try await callable.call([
            "provider": provider,
            "credential": credential,
            "credentialKind": kind.rawValue
        ])
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized ?? data),
              let doc = try? JSONDecoder().decode(ProviderConnectionDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func deleteProviderCredential(provider: String) async throws {
        let callable = functions.httpsCallable("deleteProviderCredential")
        _ = try await callable.call(["provider": provider])
    }

    func refreshProviderQuota(provider: String) async throws -> ProviderQuotaSnapshot {
        let callable = functions.httpsCallable("refreshProviderQuota")
        let result = try await callable.call(["provider": provider])
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized ?? data),
              let snap = try? JSONDecoder().decode(ProviderQuotaSnapshot.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return snap
    }

    func rebuildUsageRollups() async throws {
        let callable = functions.httpsCallable("rebuildUsageRollups")
        _ = try await callable.call([:])
    }
}

// MARK: - Functions Error

enum FunctionsError: Error, LocalizedError {
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .decodingFailed: return "Failed to decode cloud function response."
        }
    }
}
