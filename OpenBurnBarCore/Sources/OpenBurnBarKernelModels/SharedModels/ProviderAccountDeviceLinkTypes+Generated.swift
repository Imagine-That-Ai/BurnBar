import Foundation
import OpenBurnBarFirestoreModels
import OpenBurnBarKernelPlatform

// MARK: - Generated-canon bridge (TypeSpec strangler)
//
// remediation(typespec-strangler): first production consumer of the generated
// `OpenBurnBarFirestoreModels` target. The generated `Firestore*Doc` types are
// the flat wire shape (every field String/Int, dates as ISO-8601 strings); the
// hand-rolled `ProviderAccountDeviceLinkDoc` is the rich in-memory domain model
// (typed `DeviceLinkCapability` / `DeviceLinkStatus` enums, `Date` timestamps).
//
// This file makes the generated path load-bearing: it imports the generated
// module and reads a generated type's fields to build the domain model, so a
// schema drift that renames or retypes a `FirestoreProviderAccountDeviceLinkDoc`
// field now breaks the OpenBurnBarCore build (and everything that links it),
// not just the test target. We bridge — rather than replace — the hand mirror
// so existing call sites that switch on the typed enums and compare `Date`s
// keep compiling unchanged.
//
// Direction is wire -> domain only: the generated structs expose no public
// initializer across the module boundary (their memberwise init is internal to
// `OpenBurnBarFirestoreModels`), and read-on-decode is the realistic strangler
// consumption pattern anyway. The field set is verified structurally
// equivalent to the generated canon (id, accountID, deviceID, deviceDisplayName,
// capability, status, lastObservedAt, createdAt, updatedAt, schemaVersion).

public extension ProviderAccountDeviceLinkDoc {

    /// Build the rich domain model from the generated wire document.
    ///
    /// Fails closed: an unrecognized `capability`/`status` raw value or an
    /// unparseable ISO-8601 timestamp returns `nil` rather than silently
    /// coercing to a default, matching the strict decode posture the manual
    /// dictionary decoders already use.
    init?(generated doc: FirestoreProviderAccountDeviceLinkDoc) {
        guard
            let capability = DeviceLinkCapability(rawValue: doc.capability),
            let status = DeviceLinkStatus(rawValue: doc.status),
            let lastObservedAt = ThreadSafeISO8601DateFormatter.parse(doc.lastObservedAt),
            let createdAt = ThreadSafeISO8601DateFormatter.parse(doc.createdAt),
            let updatedAt = ThreadSafeISO8601DateFormatter.parse(doc.updatedAt)
        else {
            return nil
        }
        self.init(
            id: doc.id,
            accountID: doc.accountID,
            deviceID: doc.deviceID,
            deviceDisplayName: doc.deviceDisplayName,
            capability: capability,
            status: status,
            lastObservedAt: lastObservedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            schemaVersion: doc.schemaVersion
        )
    }
}
