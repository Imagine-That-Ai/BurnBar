import FirebaseAuth
import FirebaseCore
import Foundation
import OpenBurnBarComputerUseCore

enum MobileAppCheckAttestationReader {
    static func currentAttestationDigestForEnvelope() async -> String? {
        guard FirebaseApp.app() != nil else { return nil }
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        do {
            let result = try await user.getIDTokenResult(forcingRefresh: false)
            guard let claim = AppCheckAttestationBinding.parseClaim(from: result.claims as? [String: Any]),
                  AppCheckAttestationBinding.isFresh(claim) else {
                return nil
            }
            return AppCheckAttestationBinding.digestHex(for: claim)
        } catch {
            return nil
        }
    }
}
