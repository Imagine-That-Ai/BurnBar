// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import OpenBurnBarUsageModels

/// Stable credential identity for per-usage requests. Hashes the Bearer [REDACTED] so the
/// raw secret never leaves the call frame; the resulting slot ID lines up with what the
/// usage row stores under `providerAccountID`.
///
/// Unified from the byte-identical `AgentLensCredentialIdentity` (macOS) and
/// `MobileCredentialIdentity` (iOS) twins, which shared the same FNV-1a slot hash.
public enum BudgetCredentialIdentityBuilder {
    public static func make(
        providerHint: String,
        bearerToken: String?,
        displayLabel: String,
        providerAccountID: String? = nil,
        providerAccountLabel: String? = nil
    ) -> BudgetCredentialIdentity {
        let secret = bearerToken ?? ""
        let mode = BudgetCredentialIdentity.billingMode(forSecretPrefix: secret)
        let slotID = secret.isEmpty ? "default" : hashedSlotID(secret)
        return BudgetCredentialIdentity(
            providerID: providerHint,
            slotID: slotID,
            displayLabel: displayLabel,
            providerAccountID: providerAccountID,
            providerAccountLabel: providerAccountLabel,
            billingMode: mode
        )
    }

    private static func hashedSlotID(_ secret: String) -> String {
        // Cheap stable FNV-1a hash — collisions are acceptable for slot identity
        // since the user labels their credentials.
        var hash: UInt64 = 14695981039346656037
        for byte in secret.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 36, uppercase: false)
    }
}
