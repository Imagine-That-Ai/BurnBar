import Foundation
import OpenBurnBarKernel
import os

// MARK: - Team fact rewrap (memory program D16 / P21, PR 2)
//
// Re-seals every live team fact from `teamVaultKey_vN` to `v(N+1)` IN PLACE,
// under the same document id, so a rotation never orphans a team space.
//
// WHY THIS IS NOT `CloudVaultRotationRewrapWorker`. That worker is the personal
// lane's, and two things about it make it unusable here — neither of them
// incidental:
//
//   1. `rewrapCollection` is hard-wired to `userRef.collection(collectionID)`
//      (`CloudVaultRotationRewrapWorker.swift:439-491`). Team facts live at
//      `team_memory_facts/{teamId}/facts`, which is not under `users/{uid}`.
//      The genuinely reusable unit is
//      `CloudVaultCrypto.rewrapCloudVaultDocument(_:uid:collection:docID:…)`,
//      whose `uid` is only ever an AAD part — so `uid: "team:\(teamId)"` slots
//      straight in and produces the exact AAD the team fact was sealed under.
//
//   2. ITS UPDATE PAYLOAD STAMPS `updatedAt`. On a team fact that is not a
//      cosmetic difference, it is a permanent outage: `MemoryCloudPullService`
//      requires the outer `updatedAt` to match the one sealed INSIDE the
//      envelope within a second, refuses `.updatedAtMismatch` when it does not,
//      and treats that refusal as non-permanent — which freezes the pull
//      watermark FOR EVER, for every member of the team, on the first rotation.
//      This worker therefore writes `sealedMemory`, `teamKeyVersion` and
//      `rewrapJobId`, and nothing else. `updatedAt` is not in the payload and
//      `test_rewrap_does_not_touch_the_outer_updated_at` keeps it out.
//
// It also stamps NO `vaultGeneration`: that field is a personal-vault concept
// and is deliberately absent from the team fact allowlist in `firestore.rules`,
// so writing it would be rejected outright.

struct TeamCloudVaultRewrapProgress: Equatable, Sendable {
    let scannedDocuments: Int
    let rewrappedDocuments: Int
    /// Facts the pass could not re-seal and deliberately did NOT throw on: the
    /// ring holds no key for the generation the fact names, or the blob refused
    /// to open under the key it does hold. Reported, never fatal — one
    /// unreadable document must not strand every other fact in the team
    /// (PR 2 review B2).
    let skippedDocuments: Int

    /// A pass is complete only when it scanned the space and left nothing
    /// behind. `rewrappedDocuments == 0` is a perfectly good complete pass: it
    /// is what a re-run of a finished rotation looks like.
    var isComplete: Bool { skippedDocuments == 0 }
}

/// A rewrap pass that finished with nothing left behind.
struct TeamRewrapCompletion: Equatable, Sendable {
    let jobId: String
    let teamKeyVersion: Int
}

/// Where "the re-key actually finished" is recorded (PR 2 review N1).
///
/// `rotateTeamKey` clears `keyRotationRequired` and advances `activeKeyVersion`
/// BEFORE a single fact is re-sealed — it has to, because `firestore.rules`
/// pins every fact write to the roster's active generation. So a roster that
/// says "rotated" says nothing about whether the corpus was ever re-keyed, and
/// without a marker the next cycle cannot tell a finished rotation from one that
/// never got past the callable.
///
/// THERE IS NO SERVER FIELD FOR THIS, and PR 2 does not invent one:
/// `team_rosters/**` is `allow write: if false`, and neither callable this lane
/// drives (`promoteTeamMember`, `rotateTeamKey` — both PR 1's shipped surface)
/// accepts a rewrap marker. Adding one would be a roster-schema change in a PR
/// that ships no UI to read it. The smallest honest option is a LOCAL note,
/// which is enough for what it has to decide: whether the next pass on THIS
/// machine is resuming an unfinished re-key or re-running a finished one. It
/// holds a job id and a key generation, nothing secret, so it lives in
/// `UserDefaults` rather than the Keychain. PR 4 promotes it to a roster field
/// written by `rotateTeamKey`, so every member sees it and not just the admin
/// who happened to run the pass.
protocol TeamRewrapCompletionRecording: Sendable {
    func completedRewrap(teamId: String) -> TeamRewrapCompletion?
    func recordCompletedRewrap(_ completion: TeamRewrapCompletion, teamId: String)
}

struct UserDefaultsTeamRewrapCompletionStore: TeamRewrapCompletionRecording {
    static let defaultsKeyPrefix = "com.openburnbar.team-rewrap-completed."

    func completedRewrap(teamId: String) -> TeamRewrapCompletion? {
        guard let raw = UserDefaults.standard.string(forKey: Self.defaultsKey(teamId: teamId)) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let teamKeyVersion = Int(parts[0]) else { return nil }
        return TeamRewrapCompletion(jobId: String(parts[1]), teamKeyVersion: teamKeyVersion)
    }

    func recordCompletedRewrap(_ completion: TeamRewrapCompletion, teamId: String) {
        UserDefaults.standard.set(
            "\(completion.teamKeyVersion)|\(completion.jobId)",
            forKey: Self.defaultsKey(teamId: teamId)
        )
    }

    private static func defaultsKey(teamId: String) -> String { "\(defaultsKeyPrefix)\(teamId)" }
}

/// Walks `team_memory_facts/{teamId}/facts` through `CloudSyncFirestoreGateway`
/// — never a raw `Firestore.firestore()` handle — and re-seals each fact's
/// `sealedMemory` under the new team key.
struct TeamCloudVaultRewrapWorker: Sendable {
    /// NO DATA-DOMAIN REGISTRY ENTRY IN THIS PR (PR 2 review, concern 4). The
    /// registry is not a private index: every entry is rendered unconditionally
    /// on `burnbar.ai/privacy`, in the Android privacy labels and in the macOS
    /// Control Center, and it carries no `status`/`unreleased` concept that
    /// could hide one. Landing a "Team Memory" row here would publish public
    /// trust copy for a feature no user can create until PR 4 ships the UI. The
    /// entry moves to that PR, with the surface it describes.
    ///
    /// Nothing in this lane depends on registry discovery: the rotation flow
    /// invokes this worker DIRECTLY (`TeamVaultKeyDistributor.rotateTeamKey`),
    /// unlike the personal lane, which is data-driven over
    /// `CloudVaultRotationRewrapWorker.documentRewrapDomains`. When the entry
    /// does land, its `firestorePaths` must stay EMPTY: that field means
    /// "per-user subcollection" to every consumer — both the macOS and iOS
    /// personal rewrap workers iterate it as `userRef.collection(id)` — so
    /// naming `team_memory_facts` there would send a PERSONAL rotation walking a
    /// user subcollection that does not exist and that the rules deny.
    static let factsRootCollection = "team_memory_facts"
    static let factsSubcollection = "facts"
    /// The AAD `collection` part every team fact was sealed under. It is the
    /// ROOT collection name, not the full path, matching what
    /// `firestore.rules` builds:
    /// `cloudVaultAADContext("team:" + teamId, "team_memory_facts", docID, "sealedMemory")`.
    static let aadCollection = "team_memory_facts"
    static let sealedField = "sealedMemory"

    private static let logger = Logger(subsystem: "com.openburnbar.cloudsync", category: "TeamCloudVaultRewrapWorker")

    let gateway: CloudSyncFirestoreGateway
    var batchLimit: Int = 50
    var completionRecorder: TeamRewrapCompletionRecording = UserDefaultsTeamRewrapCompletionStore()

    /// Re-seal every fact in the team space under `newKeyData`.
    ///
    /// Runs AFTER `rotateTeamKey` has recorded the new generation, because
    /// `firestore.rules` pins every fact write to
    /// `d.teamKeyVersion == activeTeamKeyVersion(teamId)` — see the ordering
    /// note on `TeamVaultKeyDistributor.rotateTeamKey`.
    ///
    /// EVERY GENERATION, NOT JUST "THE PREVIOUS ONE" (PR 2 review B2). The
    /// opening key is chosen per document, from that document's OWN key version,
    /// looked up in the ring — never assumed to be `newTeamKeyVersion - 1`. Two
    /// ordinary interruptions are enough to spread a corpus across three
    /// generations: a rotation `N -> N+1` dies mid-collection, a second
    /// departure raises `keyRotationRequired`, and an admin rotates
    /// `N+1 -> N+2`. A worker that only knew "the old key" would reach the first
    /// fact still at `vN`, fail to open it and abort — after the callable had
    /// already recorded `N+2`, leaving those facts permanently un-rewrapped and,
    /// because the rules pin writes to the active version, permanently
    /// unwritable. That is the stranded team this lane exists to prevent.
    ///
    /// A fact whose generation is not in the ring (or whose blob will not open
    /// under the key that is) is COUNTED and skipped; the pass finishes over the
    /// rest and reports the count, so an admin sees "812 re-sealed, 3 skipped"
    /// instead of a rotation that stops on document four.
    func runRewrap(
        teamId: String,
        jobId: String,
        keyRing: TeamVaultKeyRing,
        newKeyData: Data,
        newTeamKeyVersion: Int
    ) async throws -> TeamCloudVaultRewrapProgress {
        let newVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: newKeyData)
        var scanned = 0
        var rewrapped = 0
        var skipped = 0
        var lastDocumentID: String?
        var keysByVersion: [Int: Data?] = [newTeamKeyVersion: newKeyData]

        while true {
            var query = factsCollection(teamId: teamId)
                .orderByDocumentID(descending: false)
                .limit(to: batchLimit)
            if let lastDocumentID {
                query = query.whereDocumentID(isGreaterThan: lastDocumentID)
            }
            let snapshot = try await query.getDocuments()
            if snapshot.documents.isEmpty { break }

            for document in snapshot.documents {
                scanned += 1
                let data = document.data()
                let docID = document.documentID
                // RESUMABILITY. A pass that dies halfway leaves facts at several
                // generations at once, and the re-run must tolerate that. Unlike
                // a sealed PAYLOAD (which carries a `vaultKeyID` the shared
                // rewrapper compares first), a blob envelope has no key label
                // the rewrapper reads — so the SOURCE generation has to be read
                // off the document and its key looked up, or the rewrapper would
                // try to open an already-rotated fact with the wrong key and
                // throw. `sealedMemory.keyVersion` is the envelope's own label
                // and the one the rules keep equal to the outer
                // `teamKeyVersion`; the outer field is the fallback for a
                // document whose envelope shape cannot be read.
                let sourceVersion = Self.sourceKeyVersion(of: data)
                guard let sourceVersion else {
                    skipped += 1
                    Self.logger.warning("Team fact \(docID, privacy: .public) names no key version; skipped.")
                    continue
                }
                if sourceVersion == newTeamKeyVersion { continue }
                let cachedKey: Data?
                if let known = keysByVersion[sourceVersion] {
                    cachedKey = known
                } else {
                    let fetched = try Self.openingKey(
                        teamId: teamId,
                        version: sourceVersion,
                        keyRing: keyRing
                    )
                    keysByVersion[sourceVersion] = fetched
                    cachedKey = fetched
                }
                guard let sourceKey = cachedKey else {
                    // A generation this device never received an envelope for.
                    // Counted, not thrown: another admin holds it, and stopping
                    // here would leave every LATER fact un-rewrapped too.
                    skipped += 1
                    Self.logger.warning(
                        "Team fact \(docID, privacy: .public) is sealed under a team key generation this device does not hold; skipped."
                    )
                    continue
                }
                // DOC ID IS NEVER RECOMPUTED. It is an HMAC under the
                // non-rotating `teamSlugKey`, so it survives a vault-key
                // rotation untouched — the fact is re-sealed at the same
                // address, and every member's convergence identity for it still
                // resolves. Rotating the naming key instead would orphan the
                // whole space.
                let result: CloudVaultDocumentRewrapResult
                do {
                    result = try CloudVaultCrypto.rewrapCloudVaultDocument(
                        data,
                        uid: Self.aadUID(teamId: teamId),
                        collection: Self.aadCollection,
                        docID: docID,
                        oldKeyData: sourceKey,
                        newKeyData: newKeyData,
                        newVaultKeyID: newVaultKeyID,
                        // NO vaultGeneration (not on the team allowlist) and no
                        // rotationJobId here: `rewrapJobId` is stamped explicitly
                        // in `updatePayload` so the written field set stays a
                        // closed, reviewable list rather than whatever the shared
                        // rewrapper decides to add.
                        vaultGeneration: nil,
                        rotationJobId: nil
                    )
                } catch {
                    // The label said one generation and the ciphertext disagreed
                    // — a corrupt or hand-edited document. One of those must not
                    // strand the rest of the team's corpus.
                    skipped += 1
                    Self.logger.warning(
                        "Team fact \(docID, privacy: .public) would not open under the key its version names: \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
                guard result.changed else { continue }
                guard let payload = Self.updatePayload(
                    from: result,
                    jobId: jobId,
                    newTeamKeyVersion: newTeamKeyVersion
                ) else {
                    skipped += 1
                    Self.logger.warning("Team fact \(docID, privacy: .public) rewrapped without a sealed envelope; skipped.")
                    continue
                }
                try await factsCollection(teamId: teamId).document(docID).setData(payload, merge: true)
                rewrapped += 1
            }

            lastDocumentID = snapshot.documents.last?.documentID
            if snapshot.documents.count < batchLimit { break }
        }

        let progress = TeamCloudVaultRewrapProgress(
            scannedDocuments: scanned,
            rewrappedDocuments: rewrapped,
            skippedDocuments: skipped
        )
        if progress.isComplete {
            // COMPLETION SIGNAL (PR 2 review N1). Only a pass that left nothing
            // behind records one, so "the roster says rotated" and "the corpus
            // is actually re-keyed" stop being the same claim.
            completionRecorder.recordCompletedRewrap(
                TeamRewrapCompletion(jobId: jobId, teamKeyVersion: newTeamKeyVersion),
                teamId: teamId
            )
        }
        return progress
    }

    /// The key that opens a generation: the ACTIVE ring slot, then the PENDING
    /// one (PR 2 review, nit 1).
    ///
    /// `TeamVaultKeyDistributor.rotateTeamKey` promotes `v(N+1)` from pending to
    /// active only AFTER the `rotateTeamKey` callable has returned. If that
    /// promotion throws — a Keychain error, a crash in the millisecond between
    /// the two — the roster records `N+1` while this Mac holds it only as
    /// pending. Wrapping still works (`requireKey` already falls back), but a
    /// LATER rotation's rewrap would reach every fact this pass re-sealed at
    /// `N+1`, find no active slot, and count the entire corpus as
    /// `skippedDocuments` for ever.
    ///
    /// The fallback cannot resurrect an abandoned mint by mistake: a pending
    /// generation whose callable never ran is a generation the roster never
    /// recorded, and `firestore.rules` pins every fact write to the roster's
    /// active version — so no document can name it. And if the bytes were
    /// somehow wrong, `rewrapCloudVaultDocument` throws and the document is
    /// counted and skipped exactly as before; nothing is written under a key
    /// that did not open it.
    static func openingKey(teamId: String, version: Int, keyRing: TeamVaultKeyRing) throws -> Data? {
        if let active = try keyRing.key(teamId: teamId, slot: .vault(version: version)) { return active }
        guard let pending = try keyRing.pendingKey(teamId: teamId, slot: .vault(version: version)) else {
            return nil
        }
        logger.notice(
            "Opening team facts at generation \(version, privacy: .public) with the PENDING ring slot: the roster recorded it but this Mac never promoted it."
        )
        return pending
    }

    /// The generation a fact is sealed under: the envelope's own `keyVersion`
    /// first (the label `firestore.rules` keeps equal to the outer one), the
    /// outer `teamKeyVersion` as a fallback.
    static func sourceKeyVersion(of data: [String: Any]) -> Int? {
        if let sealed = data[Self.sealedField] as? [String: Any],
           let keyVersion = sealed["keyVersion"] as? Int {
            return keyVersion
        }
        return data["teamKeyVersion"] as? Int
    }

    /// The AAD `uid` slot for a team space. `CloudVaultAADContext` validates
    /// each part only for control characters and `|`, so `team:<teamId>` is a
    /// legal part today and needs no new crypto primitive — the same string
    /// `firestore.rules` concatenates.
    static func aadUID(teamId: String) -> String {
        "team:\(teamId)"
    }

    /// EXACTLY THREE FIELDS. `sealedMemory` (the re-sealed envelope),
    /// `teamKeyVersion` (the outer label the rules pin to the roster's active
    /// generation) and `rewrapJobId`. Returns `nil` when the rewrap produced no
    /// sealed envelope, so a malformed document is skipped rather than written
    /// with a partial payload.
    ///
    /// `updatedAt` IS DELIBERATELY ABSENT. See the file header: stamping it
    /// breaks the sealed/outer `updatedAt` agreement `MemoryCloudPullService`
    /// enforces and permanently freezes every member's pull watermark.
    ///
    /// The sealed envelope's own `keyVersion` is rewritten to the new team
    /// generation because the shared rewrapper re-seals at
    /// `CloudVaultCrypto.currentKeyVersion` (1) — it has no idea a team key
    /// generation exists — while the rules require
    /// `d.sealedMemory.keyVersion == d.teamKeyVersion`. That is a safe rewrite:
    /// `keyVersion` sits outside the ciphertext AND outside the AAD, so it is a
    /// key-SELECTION hint; the keyed `plaintextHMAC` inside the envelope is what
    /// actually proves which key sealed the blob.
    static func updatePayload(
        from result: CloudVaultDocumentRewrapResult,
        jobId: String,
        newTeamKeyVersion: Int
    ) -> [String: Any]? {
        guard result.changedFields.contains(Self.sealedField),
              var sealed = result.data[Self.sealedField] as? [String: Any] else {
            return nil
        }
        sealed["keyVersion"] = newTeamKeyVersion
        return [
            Self.sealedField: sealed,
            "teamKeyVersion": newTeamKeyVersion,
            "rewrapJobId": jobId
        ]
    }

    private func factsCollection(teamId: String) -> CloudSyncCollectionGateway {
        gateway
            .collection(Self.factsRootCollection)
            .document(teamId)
            .collection(Self.factsSubcollection)
    }
}
