#if canImport(AppKit)
import FirebaseAuth
import Foundation
import OpenBurnBarComputerUseCore

/// Reads the bound `obb_app_check` claim from the signed-in Mac user's ID token.
enum MacAppCheckAttestationReader {
    static func currentRequiredAttestationDigest() async -> String? {
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

    static func attestationRequirement(strictMode: Bool) async -> PhoneControlAttestationRequirement {
        let macBound = await currentRequiredAttestationDigest() != nil
        return PhoneControlAttestationPolicy.requirement(
            strictMode: strictMode,
            macHostHasBoundClaim: macBound
        )
    }
}
#endif