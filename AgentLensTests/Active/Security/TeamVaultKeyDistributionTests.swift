import CryptoKit
import FirebaseFunctions
import Foundation
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBar

/// Team key distribution, rotation and rewrap (memory program D16 / P21, PR 2).
///
/// Every case here is a way the lane could quietly become unusable rather than
/// loudly broken: a member wrapped once instead of once per device, a joiner
/// promoted without the key for a fact written before they arrived, an
/// ex-member still handed the next key, a rotation that renames every document,
/// or a rewrap that stamps the one field which permanently freezes every
/// member's pull cursor. None of those raise an error at the time; they surface
/// weeks later as "team memory looks empty".
final class TeamVaultKeyDistributionTests: XCTestCase {
    private let teamId = "team_0123456789abcdef"
    private let adminUid = "pr2-admin"
    private let joinerUid = "pr2-joiner"
    private let departedUid = "pr2-departed"

    // MARK: - Key distribution

    func test_a_team_key_is_wrapped_per_device_not_per_member() async throws {
        // The escrow private key that opens a wrap lives in ONE Mac's Keychain
        // (`cloud-vault-device:<deviceId>`). A member's second Mac holds a
        // different one, so a single wrap per member would leave that Mac
        // permanently unable to open the team space while the roster happily
        // reported the member "active". Two devices must produce two envelopes,
        // each addressed to its own device and wrapped to ITS OWN public key.
        let world = TeamKeyWorld()
        let laptop = world.enrolDevice(uid: joinerUid, deviceId: "device-laptop", escrowKeyVersion: 1)
        let desktop = world.enrolDevice(uid: joinerUid, deviceId: "device-desktop", escrowKeyVersion: 3)
        world.seedMember(uid: joinerUid, pins: [laptop.pin, desktop.pin])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        let published = try await distributor.wrapKeysForMember(
            teamId: teamId,
            recipientUid: joinerUid,
            slots: [.vault(version: 1)]
        )

        XCTAssertEqual(
            published.envelopeIds.sorted(),
            ["\(joinerUid)_device-desktop_3_v1", "\(joinerUid)_device-laptop_1_v1"],
            "one envelope per DEVICE, named {uid}_{deviceId}_{escrowKeyVersion}_{keySlot}"
        )

        // Each envelope opens with that device's private key, and only that one.
        let laptopEnvelope = try world.envelope(id: "\(joinerUid)_device-laptop_1_v1")
        let desktopEnvelope = try world.envelope(id: "\(joinerUid)_device-desktop_3_v1")
        XCTAssertEqual(try laptop.unwrapTeamKey(world.wrappedKey(in: laptopEnvelope)), world.teamVaultKeyV1)
        XCTAssertEqual(try desktop.unwrapTeamKey(world.wrappedKey(in: desktopEnvelope)), world.teamVaultKeyV1)
        XCTAssertThrowsError(try laptop.unwrapTeamKey(world.wrappedKey(in: desktopEnvelope)))

        // The recipient fingerprint is the base64 escrow fingerprint the roster
        // pinned — the shape `firestore.rules` requires — and `wrappedBy` is the
        // admin, so the roster authority can count this wrap toward coverage.
        XCTAssertEqual(laptopEnvelope["recipientPublicKeyFingerprint"] as? String, laptop.pin.publicKeyFingerprint)
        XCTAssertEqual(laptopEnvelope["wrappedBy"] as? String, adminUid)
        XCTAssertEqual(laptopEnvelope["uid"] as? String, joinerUid)
        XCTAssertEqual(laptopEnvelope["algorithm"] as? String, "ECIES-P256-AESGCM")
    }

    func test_a_join_receives_an_envelope_for_every_retained_key_version() async throws {
        // A member who only gets the CURRENT key is active-but-blind to every
        // fact written before the last rotation — and those facts are exactly
        // the team's history. `promoteTeamMember` is called only after an
        // envelope exists for every retained version PLUS the non-rotating slug
        // key, without which the joiner could decrypt facts but not name them.
        let world = TeamKeyWorld()
        let device = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: joinerUid, pins: [device.pin])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try distributor.keyRing.store(world.teamVaultKeyV2, teamId: teamId, slot: .vault(version: 2))
        try distributor.keyRing.store(world.teamSlugKey, teamId: teamId, slot: .slug)

        let published = try await distributor.issueJoinerKeys(
            teamId: teamId,
            joinerUid: joinerUid,
            retainedKeyVersions: [2, 1]
        )

        XCTAssertEqual(
            published.envelopeIds,
            ["\(joinerUid)_device-j_1_v1", "\(joinerUid)_device-j_1_v2", "\(joinerUid)_device-j_1_slug"],
            "every retained version, then the slug key"
        )
        // The joiner really can open a PRE-rotation fact: the v1 envelope
        // carries v1, not a re-labelled copy of the current key.
        XCTAssertEqual(
            try device.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(joinerUid)_device-j_1_v1"))),
            world.teamVaultKeyV1
        )
        XCTAssertEqual(
            try device.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(joinerUid)_device-j_1_slug"))),
            world.teamSlugKey
        )

        // Promotion happens after publication, with the exact id set.
        XCTAssertEqual(
            world.callables.promotions,
            [RecordingTeamRosterCallables.Promotion(
                teamId: teamId,
                uid: joinerUid,
                envelopeIds: published.envelopeIds
            )]
        )
    }

    func test_a_departed_member_receives_no_new_envelope() async throws {
        // Rotation is what actually revokes a departed member: the roster cutoff
        // stops their reads, and the new key stops their decrypts. Handing them
        // an envelope for v(N+1) would undo the whole point of rotating, and it
        // would do so silently.
        let world = TeamKeyWorld()
        let staying = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        let leaving = world.enrolDevice(uid: departedUid, deviceId: "device-x", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [staying.pin], role: "admin")
        world.seedMember(uid: departedUid, pins: [leaving.pin], status: "removed")

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try distributor.keyRing.store(world.teamSlugKey, teamId: teamId, slot: .slug)

        // The caller passes the REMAINING ACTIVE members; the departed uid is
        // not among them, so no wrap is even attempted for it.
        _ = try await distributor.rotateTeamKey(
            teamId: teamId,
            activeKeyVersion: 1,
            newKeyVersion: 2,
            activeMemberUids: [adminUid],
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-1"
        )

        let envelopeIds = Set(world.envelopeIds())
        XCTAssertTrue(envelopeIds.contains("\(adminUid)_device-admin_1_v2"))
        XCTAssertTrue(
            envelopeIds.allSatisfy { !$0.hasPrefix("\(departedUid)_") },
            "a removed member must not be handed the key that replaces the one they already have"
        )
        XCTAssertEqual(world.callables.rotations.first?.newKeyVersion, 2)
    }

    func test_the_slug_key_survives_a_rotation() async throws {
        // Document ids are HMACs under the slug key. Rotating it would give
        // every fact a new address — the team space would not be re-keyed, it
        // would be ORPHANED, and every member's convergence identity for those
        // facts would stop resolving. A rotation therefore issues vault-key
        // envelopes only, and the ring keeps the same slug key it started with.
        let world = TeamKeyWorld()
        let device = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [device.pin], role: "admin")

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try distributor.keyRing.store(world.teamSlugKey, teamId: teamId, slot: .slug)
        let docIDBefore = try CloudVaultCrypto.pensieveSlugHmac(
            "team-memory-fact:\(teamId):abc",
            keyData: world.teamSlugKey
        )

        _ = try await distributor.rotateTeamKey(
            teamId: teamId,
            activeKeyVersion: 1,
            newKeyVersion: 2,
            activeMemberUids: [adminUid],
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-slug"
        )

        let slugAfter = try XCTUnwrap(try distributor.keyRing.key(teamId: teamId, slot: .slug))
        XCTAssertEqual(slugAfter, world.teamSlugKey, "the slug key is not regenerated by a rotation")
        XCTAssertEqual(
            try CloudVaultCrypto.pensieveSlugHmac("team-memory-fact:\(teamId):abc", keyData: slugAfter),
            docIDBefore
        )
        XCTAssertFalse(
            world.envelopeIds().contains { $0.hasSuffix("_slug") },
            "a rotation must not re-issue the non-rotating slug key"
        )
        XCTAssertNotNil(try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 1)))
        XCTAssertNotNil(try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2)))
    }

    func test_an_envelope_for_an_unpinned_fingerprint_is_never_written() async throws {
        // The pinned fingerprint is the ONLY thing standing between a wrap and a
        // substituted recipient key. Two independent ways it can be wrong, both
        // refused, and — because envelopes are create-only and immutable — with
        // ZERO documents written, so a rejected device can never leave a
        // half-published id set that nobody is allowed to repair.
        let world = TeamKeyWorld()
        let good = world.enrolDevice(uid: joinerUid, deviceId: "device-good", escrowKeyVersion: 1)
        let swapped = world.enrolDevice(uid: joinerUid, deviceId: "device-swapped", escrowKeyVersion: 1)

        // (1) The roster pinned a fingerprint that is not the one this device
        // published — a key rotated in after the pin was taken.
        let attackerKey = P256.KeyAgreement.PrivateKey()
        let attackerFingerprint = Data(SHA256.hash(data: attackerKey.publicKey.x963Representation))
            .base64EncodedString()
        world.seedMember(uid: joinerUid, pins: [
            good.pin,
            TeamEscrowDevicePin(
                deviceId: swapped.pin.deviceId,
                escrowKeyVersion: swapped.pin.escrowKeyVersion,
                publicKeyFingerprint: attackerFingerprint
            )
        ])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        await assertThrows(.fingerprintNotPinned(uid: joinerUid, deviceId: "device-swapped")) {
            try await distributor.wrapKeysForMember(
                teamId: self.teamId,
                recipientUid: self.joinerUid,
                slots: [.vault(version: 1)]
            )
        }
        XCTAssertTrue(
            world.envelopeIds().isEmpty,
            "verification happens before ANY write, so the good device's envelope is not published either"
        )

        // (2) The fingerprint matches the pin but is not the digest of the key
        // bytes it names — a backend that swapped the bytes and kept the string.
        // `EscrowDeviceSafetyCode.isFingerprint` is what catches this, and
        // trusting check (1) alone would be trusting the server to have stored a
        // self-consistent document.
        world.seedEscrowPublicKey(
            uid: joinerUid,
            deviceId: good.pin.deviceId,
            escrowKeyVersion: good.pin.escrowKeyVersion,
            publicKeyBase64: attackerKey.publicKey.x963Representation.base64EncodedString(),
            fingerprint: good.pin.publicKeyFingerprint
        )
        world.seedMember(uid: joinerUid, pins: [good.pin])

        await assertThrows(.fingerprintNotBoundToKey(uid: joinerUid, deviceId: "device-good")) {
            try await distributor.wrapKeysForMember(
                teamId: self.teamId,
                recipientUid: self.joinerUid,
                slots: [.vault(version: 1)]
            )
        }
        XCTAssertTrue(world.envelopeIds().isEmpty)
    }

    func test_a_self_wrap_only_targets_the_current_uid() async throws {
        // `firestore.rules` lets a plain member create an envelope only when
        // `request.resource.data.uid == request.auth.uid` — self-wrap, which is
        // how a founder bootstraps and how a member enrols a second Mac. The
        // client mirrors that boundary: `selfWrapKeys` takes NO recipient, reads
        // this account's OWN roster row, and refuses if it is ever handed
        // someone else's uid. A roster full of other members with pinned devices
        // must produce envelopes for this account and nobody else.
        let world = TeamKeyWorld()
        let mine = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        let theirs = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [mine.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [theirs.pin])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        let bootstrap = try await distributor.bootstrapTeamKeys(teamId: teamId)

        XCTAssertEqual(
            bootstrap.envelopeIds,
            ["\(adminUid)_device-admin_1_v1", "\(adminUid)_device-admin_1_slug"]
        )
        XCTAssertEqual(
            Set(world.envelopeIds()),
            Set(bootstrap.envelopeIds),
            "a bootstrap wraps for THIS account only, even with another pinned member on the roster"
        )
        for id in bootstrap.envelopeIds {
            let envelope = try world.envelope(id: id)
            XCTAssertEqual(envelope["uid"] as? String, adminUid, "a self-wrap is addressed to this account")
            XCTAssertEqual(envelope["wrappedBy"] as? String, adminUid)
        }

        // The two keys are genuinely different keys, and the slug key id is
        // publishable: it names the key without revealing it.
        XCTAssertEqual(bootstrap.teamKeyVersion, 1)
        let slugKey = try XCTUnwrap(try distributor.keyRing.key(teamId: teamId, slot: .slug))
        let vaultKey = try XCTUnwrap(try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 1)))
        XCTAssertEqual(bootstrap.slugKeyId, try CloudVaultCrypto.vaultKeyID(for: slugKey))
        XCTAssertNotEqual(slugKey, vaultKey, "the naming key and the sealing key are two different keys")

        // The founder's own devices really can open what was self-wrapped.
        XCTAssertEqual(
            try mine.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(adminUid)_device-admin_1_v1"))),
            vaultKey
        )
        // ...and the other member's device cannot: no envelope was made for it.
        XCTAssertNil(world.gateway.documentData(
            at: "team_key_envelopes/\(teamId)/envelopes/\(joinerUid)_device-j_1_v1"
        ))
    }

    func test_the_key_ring_is_populated_from_readable_envelopes() async throws {
        // The unwrap half: a member's device turns the envelopes it can read
        // into a key ring. Envelopes for this account's OTHER Macs are wrapped
        // to a different escrow key and are skipped without failing the pass —
        // a slot this device cannot fill is a NON-PERMANENT gap, never a
        // poisoned cursor.
        let world = TeamKeyWorld()
        // v1 is the roster's ACTIVE generation and `slugKeyId` names the slug
        // key, so both land in the ACTIVE ring rather than pending (B6).
        world.seedTeam(slugKeyId: try CloudVaultCrypto.vaultKeyID(for: world.teamSlugKey))
        let thisMac = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        let otherMac = world.enrolDevice(uid: joinerUid, deviceId: "device-other", escrowKeyVersion: 1)
        world.seedMember(uid: joinerUid, pins: [thisMac.pin, otherMac.pin])

        world.seedMember(uid: adminUid, pins: [], role: "admin")
        let admin = world.distributor(uid: adminUid, deviceId: "device-admin")
        try admin.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try admin.keyRing.store(world.teamSlugKey, teamId: teamId, slot: .slug)
        _ = try await admin.wrapKeysForMember(
            teamId: teamId,
            recipientUid: joinerUid,
            slots: [.vault(version: 1), .slug]
        )
        // An envelope for a DIFFERENT member is not readable and never reaches
        // this pass; one for another of this member's Macs is readable but not
        // openable here.
        world.gateway.setDocumentData(
            ["uid": adminUid, "deviceId": "device-admin", "keySlot": "v1", "wrappedKeyBase64": "AAAA"],
            at: "team_key_envelopes/\(teamId)/envelopes/\(adminUid)_device-admin_1_v1"
        )

        let joiner = TeamVaultKeyDistributor(
            gateway: world.gateway,
            uid: joinerUid,
            deviceId: "device-j",
            keyRing: InMemoryTeamVaultKeyRing(),
            callables: world.callables,
            escrowPrivateKey: thisMac
        )
        let loaded = try await joiner.loadKeyRingFromEnvelopes(teamId: teamId)

        XCTAssertEqual(Set(loaded), [.vault(version: 1), .slug])
        XCTAssertEqual(try joiner.keyRing.key(teamId: teamId, slot: .vault(version: 1)), world.teamVaultKeyV1)
        XCTAssertEqual(try joiner.keyRing.key(teamId: teamId, slot: .slug), world.teamSlugKey)
    }

    // MARK: - Rewrap

    func test_rewrap_reseals_in_place_and_does_not_change_the_doc_id() async throws {
        // The whole reason document ids are HMAC'd under the NON-rotating slug
        // key: a rotation re-seals content at the same address. If the id moved,
        // every member's engine would treat the re-sealed fact as a brand new
        // one and the old one as permanently unreachable.
        let world = TeamKeyWorld()
        let docID = try CloudVaultCrypto.pensieveSlugHmac(
            "team-memory-fact:\(teamId):converge-1",
            keyData: world.teamSlugKey
        )
        let body = Data("a decision the team made".utf8)
        try world.seedTeamFact(docID: docID, body: body, keyData: world.teamVaultKeyV1, teamKeyVersion: 1)

        try world.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        let progress = try await world.rewrapWorker().runRewrap(
            teamId: teamId,
            jobId: "job-rewrap",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV2,
            newTeamKeyVersion: 2
        )

        XCTAssertEqual(
            progress,
            TeamCloudVaultRewrapProgress(scannedDocuments: 1, rewrappedDocuments: 1, skippedDocuments: 0)
        )
        let facts = world.gateway.documents(under: "team_memory_facts/\(teamId)/facts")
        XCTAssertEqual(
            Array(facts.keys),
            ["team_memory_facts/\(teamId)/facts/\(docID)"],
            "the fact is re-sealed at the SAME id — no new document, no orphan"
        )

        let fact = try XCTUnwrap(facts.values.first)
        XCTAssertEqual(fact["teamKeyVersion"] as? Int, 2)
        XCTAssertEqual(fact["rewrapJobId"] as? String, "job-rewrap")

        // It genuinely opens under the NEW key with the same plaintext, and no
        // longer under the old one.
        let aad = try CloudVaultAADContext(
            uid: "team:\(teamId)",
            collection: "team_memory_facts",
            docID: docID,
            field: "sealedMemory"
        )
        let envelope = try XCTUnwrap(CloudVaultCrypto.decodeBlobEnvelope(from: fact["sealedMemory"]))
        XCTAssertEqual(try CloudVaultCrypto.openBlob(envelope, keyData: world.teamVaultKeyV2, aadContext: aad), body)
        XCTAssertThrowsError(
            try CloudVaultCrypto.openBlob(envelope, keyData: world.teamVaultKeyV1, aadContext: aad)
        )
        // The outer label and the envelope's own label agree, which is what
        // `firestore.rules` pins (`d.sealedMemory.keyVersion == d.teamKeyVersion`).
        XCTAssertEqual(envelope.keyVersion, 2)

        // Idempotent: a second pass finds nothing left to change, so a failed
        // rotation is a retry rather than a stranded team.
        let second = try await world.rewrapWorker().runRewrap(
            teamId: teamId,
            jobId: "job-rewrap",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV2,
            newTeamKeyVersion: 2
        )
        XCTAssertEqual(second.rewrappedDocuments, 0)
        XCTAssertTrue(second.isComplete, "a re-run of a finished rotation is a COMPLETE pass, not an empty one")
    }

    func test_rewrap_does_not_touch_the_outer_updated_at() async throws {
        // THE WATERMARK-FREEZE GUARD. `MemoryCloudPullService` requires the
        // outer `updatedAt` to match the one sealed inside the envelope within a
        // second, refuses `.updatedAtMismatch` when it does not, and treats that
        // refusal as NON-permanent — which freezes the pull watermark for ever.
        // The personal rewrap worker stamps `updatedAt` unconditionally; doing
        // that here would take out every member of the team on the first
        // rotation, with nothing failing loudly. Both halves are asserted: the
        // payload never names the field, and a round trip leaves it byte-equal.
        let world = TeamKeyWorld()
        let docID = try CloudVaultCrypto.pensieveSlugHmac(
            "team-memory-fact:\(teamId):converge-2",
            keyData: world.teamSlugKey
        )
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        try world.seedTeamFact(
            docID: docID,
            body: Data("body".utf8),
            keyData: world.teamVaultKeyV1,
            teamKeyVersion: 1,
            updatedAt: updatedAt
        )

        try world.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        _ = try await world.rewrapWorker().runRewrap(
            teamId: teamId,
            jobId: "job-watermark",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV2,
            newTeamKeyVersion: 2
        )

        let fact = try XCTUnwrap(
            world.gateway.documentData(at: "team_memory_facts/\(teamId)/facts/\(docID)")
        )
        XCTAssertEqual(fact["updatedAt"] as? Date, updatedAt, "the outer updatedAt must survive a rewrap untouched")
        XCTAssertEqual(fact["validFrom"] as? Date, updatedAt)

        // The payload itself names exactly three fields. Asserting the SET (not
        // just the absence of `updatedAt`) means a future field added to the
        // shared rewrapper cannot leak into a team document either — including
        // `vaultGeneration`, which the team allowlist in `firestore.rules`
        // rejects outright.
        let result = CloudVaultDocumentRewrapResult(
            data: ["sealedMemory": ["keyVersion": 1], "vaultGeneration": 9, "updatedAt": Date()],
            changedFields: ["sealedMemory"]
        )
        let payload = try XCTUnwrap(
            TeamCloudVaultRewrapWorker.updatePayload(from: result, jobId: "job-x", newTeamKeyVersion: 7)
        )
        XCTAssertEqual(Set(payload.keys), ["sealedMemory", "teamKeyVersion", "rewrapJobId"])
        XCTAssertEqual((payload["sealedMemory"] as? [String: Any])?["keyVersion"] as? Int, 7)
    }

    func test_a_personal_rotation_never_walks_the_team_fact_path() {
        // PR 4 lands the `team_pensieve` registry entry, with the UI it
        // describes — every registry row is rendered unconditionally as public
        // trust copy on burnbar.ai/privacy, in the Android privacy labels and in
        // the Control Center, and the registry has no "unreleased" concept that
        // could hide one (PR 2 review, concern 4). So the domain is now
        // discoverable...
        let team = CloudVaultRotationRewrapWorker.documentRewrapDomains.first { $0.id == "team_pensieve" }
        XCTAssertNotNil(team, "the team data-domain entry ships with the team UI in PR 4")

        // ...and its `firestorePaths` is EMPTY, which is the load-bearing half.
        // That field means "per-user subcollection" to every consumer: both the
        // macOS and iOS personal rewrap workers iterate it as
        // `userRef.collection(id)`, so a team path in that list would send a
        // PERSONAL rotation at a user subcollection that does not exist and that
        // the rules deny. The team rewrap is invoked DIRECTLY by the rotation
        // flow instead (`TeamVaultKeyDistributor.rotateTeamKey`), so nothing in
        // this lane depends on registry discovery.
        XCTAssertEqual(team?.firestorePaths, [], "team facts are not a users/{uid} subcollection")
        XCTAssertEqual(team?.storagePaths, [])
        XCTAssertFalse(
            CloudVaultRotationRewrapWorker.documentRewrapCollectionIDs.contains("team_memory_facts"),
            "team facts are NOT a users/{uid} subcollection; the personal worker must not try to walk them"
        )
        XCTAssertEqual(TeamCloudVaultRewrapWorker.factsRootCollection, "team_memory_facts")
        XCTAssertEqual(TeamCloudVaultRewrapWorker.aadUID(teamId: teamId), "team:\(teamId)")
    }

    // MARK: - Idempotent distribution (PR 2 review B1)

    func test_a_second_wrap_pass_over_existing_envelopes_is_a_no_op() async throws {
        // `firestore.rules` says `allow update, delete: if false` on an
        // envelope, and Firestore classifies `setData(merge: false)` over an
        // existing document as an UPDATE. So a retry that blindly re-publishes
        // does not overwrite — it is DENIED, on the first id the previous
        // attempt had already written, and can never make progress. The pass
        // therefore reads each id first, claims the ones already addressed to
        // this recipient/device/slot, and leaves them untouched.
        let world = TeamKeyWorld()
        let device = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: joinerUid, pins: [device.pin])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        let first = try await distributor.wrapKeysForMember(
            teamId: teamId,
            recipientUid: joinerUid,
            slots: [.vault(version: 1)]
        )
        let publishedWrap = try world.envelope(id: "\(joinerUid)_device-j_1_v1")["wrappedKeyBase64"] as? String

        let second = try await distributor.wrapKeysForMember(
            teamId: teamId,
            recipientUid: joinerUid,
            slots: [.vault(version: 1)]
        )

        XCTAssertEqual(second.envelopeIds, first.envelopeIds, "the ids are still claimed, so coverage is still asserted")
        XCTAssertEqual(world.envelopeIds().count, 1, "no second document")
        XCTAssertEqual(
            try world.envelope(id: "\(joinerUid)_device-j_1_v1")["wrappedKeyBase64"] as? String,
            publishedWrap,
            "ECIES is randomised, so an unchanged ciphertext proves the existing envelope was never rewritten"
        )

        // An id that exists but is addressed somewhere else is NOT quietly
        // claimed: somebody's wrap is sitting on an id this pass believes it
        // owns, and an envelope can never be repaired.
        let otherDevice = world.enrolDevice(uid: departedUid, deviceId: "device-d", escrowKeyVersion: 1)
        world.seedMember(uid: departedUid, pins: [otherDevice.pin])
        world.gateway.setDocumentData(
            [
                "uid": departedUid,
                "deviceId": "device-d",
                "escrowKeyVersion": 1,
                "keySlot": "v1",
                "recipientPublicKeyFingerprint": "a fingerprint the roster no longer pins"
            ],
            at: "team_key_envelopes/\(teamId)/envelopes/\(departedUid)_device-d_1_v1"
        )
        await assertThrows(.envelopeAddressedElsewhere(envelopeId: "\(departedUid)_device-d_1_v1")) {
            try await distributor.wrapKeysForMember(
                teamId: self.teamId,
                recipientUid: self.departedUid,
                slots: [.vault(version: 1)]
            )
        }
    }

    func test_an_interrupted_rotation_resumes_with_the_same_new_key() async throws {
        // THE STRANDED-TEAM CASE. `v(N+1)` used to be generated fresh on every
        // call, so a rotation that died part way through the member loop — a
        // network drop, an app quit — left some members holding envelopes for
        // one key while the retry minted a DIFFERENT one, whose envelopes could
        // never be written because the already-published ids are immutable. The
        // generation is now minted once, held as pending, and reused verbatim
        // until the roster authority has recorded it.
        let world = TeamKeyWorld()
        let adminDevice = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        let memberDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [adminDevice.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [memberDevice.pin])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        // 1. The second member's published escrow key goes missing. The pass
        //    resolves EVERY recipient before it writes ANY envelope (PR 2 review
        //    round 3, B5), so a target that cannot be verified produces ZERO
        //    documents rather than a generation half of the team holds.
        world.gateway.setDocumentData([:], at: "users/\(joinerUid)/escrow_public_keys/device-j_1")
        await assertThrows(.escrowPublicKeyUnavailable(uid: joinerUid, deviceId: "device-j", keyVersion: 1)) {
            try await distributor.rotateTeamKey(
                teamId: self.teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [self.adminUid, self.joinerUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-interrupted"
            )
        }
        XCTAssertEqual(world.envelopeIds(), [], "a refusal in the resolve phase writes nothing at all")
        let mintedOnce = try XCTUnwrap(try distributor.keyRing.pendingKey(teamId: teamId, slot: .vault(version: 2)))
        XCTAssertNil(
            try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2)),
            "a generation the roster has not recorded is pending, not active"
        )

        // 2. Now a GENUINELY partial pass: this admin's own Mac is covered, and
        //    then the roster authority is never reached, so v2 is published but
        //    unrecorded. This is the state a retry has to resume from.
        world.callables.failNextRotation(with: NSError(domain: "test-transport", code: -1009))
        do {
            _ = try await distributor.rotateTeamKey(
                teamId: teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [adminUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-interrupted"
            )
            XCTFail("the roster authority's refusal must surface")
        } catch {
            XCTAssertEqual((error as NSError).domain, "test-transport")
        }

        XCTAssertEqual(world.envelopeIds(), ["\(adminUid)_device-admin_1_v2"], "half published")
        XCTAssertNil(
            try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2)),
            "the callable refused, so nothing is promoted"
        )
        let firstEnvelope = try world.envelope(id: "\(adminUid)_device-admin_1_v2")
        let firstWrappedBase64 = firstEnvelope["wrappedKeyBase64"] as? String
        let keyFromFirstAttempt = try adminDevice.unwrapTeamKey(world.wrappedKey(in: firstEnvelope))
        XCTAssertEqual(keyFromFirstAttempt, mintedOnce, "the pass that wrote nothing still minted the generation once")

        // 3. Repair the escrow key and re-run over the whole team.
        world.seedEscrowPublicKey(
            uid: joinerUid,
            deviceId: "device-j",
            escrowKeyVersion: 1,
            publicKeyBase64: memberDevice.publicKeyBase64,
            fingerprint: memberDevice.pin.publicKeyFingerprint
        )
        _ = try await distributor.rotateTeamKey(
            teamId: teamId,
            activeKeyVersion: 1,
            newKeyVersion: 2,
            activeMemberUids: [adminUid, joinerUid],
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-interrupted"
        )

        XCTAssertEqual(
            Set(world.envelopeIds()),
            ["\(adminUid)_device-admin_1_v2", "\(joinerUid)_device-j_1_v2"]
        )
        XCTAssertEqual(
            try world.envelope(id: "\(adminUid)_device-admin_1_v2")["wrappedKeyBase64"] as? String,
            firstWrappedBase64,
            "the envelope the first attempt published was left alone"
        )
        let keyTheMemberReceived = try memberDevice.unwrapTeamKey(
            world.wrappedKey(in: try world.envelope(id: "\(joinerUid)_device-j_1_v2"))
        )
        XCTAssertEqual(
            keyTheMemberReceived,
            keyFromFirstAttempt,
            "EVERY envelope must wrap the SAME v2 — a second generation could never replace the first's immutable documents"
        )
        XCTAssertEqual(
            try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2)),
            keyFromFirstAttempt,
            "promoted to active only once the roster authority recorded it"
        )
        XCTAssertEqual(world.callables.rotations.map(\.newKeyVersion), [2, 2], "the refused attempt and its retry")
    }

    func test_an_interrupted_bootstrap_resumes_with_the_same_founding_keys() async throws {
        // Same property at team creation. A bootstrap that published the vault
        // key and then died would, on the old code, mint a brand new v1 and slug
        // key — and the slug key NAMES every document, so a second one would
        // address the whole team space somewhere else.
        let world = TeamKeyWorld()
        let device = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [device.pin], role: "admin")
        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")

        world.gateway.setDocumentData([:], at: "users/\(adminUid)/escrow_public_keys/device-admin_1")
        await assertThrows(.escrowPublicKeyUnavailable(uid: adminUid, deviceId: "device-admin", keyVersion: 1)) {
            _ = try await distributor.bootstrapTeamKeys(teamId: self.teamId)
        }
        let pendingSlug = try XCTUnwrap(try distributor.keyRing.pendingKey(teamId: teamId, slot: .slug))
        XCTAssertNil(try distributor.keyRing.key(teamId: teamId, slot: .slug), "nothing is active until it is published")

        world.seedEscrowPublicKey(
            uid: adminUid,
            deviceId: "device-admin",
            escrowKeyVersion: 1,
            publicKeyBase64: device.publicKeyBase64,
            fingerprint: device.pin.publicKeyFingerprint
        )
        let bootstrap = try await distributor.bootstrapTeamKeys(teamId: teamId)

        XCTAssertEqual(
            try distributor.keyRing.key(teamId: teamId, slot: .slug),
            pendingSlug,
            "the resumed bootstrap keeps the slug key the first attempt minted — a second one would rename every document"
        )
        XCTAssertEqual(bootstrap.slugKeyId, try CloudVaultCrypto.vaultKeyID(for: pendingSlug))
    }

    // MARK: - PR 1 Cursor round C-1 / C-4 (the client's half)

    func test_the_founder_bootstrap_self_wraps_only_slots_the_rules_permit() async throws {
        // C-1 CONFINED THE SELF-WRAP, AND THE BOOTSTRAP HAS TO STAY INSIDE IT.
        // `firestore.rules:5123-5128` now admits a non-admin self-wrap only for
        // `keySlot == "slug"` or `keySlot == "v" + activeTeamKeyVersion(teamId)`,
        // because an immutable create-only envelope id let an ordinary member
        // squat the ids the next rotation would demand and deny the team its only
        // revocation primitive for ever.
        //
        // The founder survives that twice over — `createTeam` seeds
        // `activeKeyVersion: 1` and `role: "admin", status: "active"` in ONE batch
        // (`functions/src/teamRoster.ts:279-320`), so `isTeamAdmin` already admits
        // the write — but the SECOND reason is the one worth pinning, because it
        // is the one a refactor can break without touching any rule: the two slots
        // this bootstrap publishes are exactly the two a plain member is allowed.
        // A bootstrap that started at `v2`, or added a speculative next
        // generation, would be denied at the door for every founder who was
        // somehow not yet an admin, and — far worse — would be denied for the
        // second-Mac enrolment path that reuses `selfWrapKeys`. The unit under
        // test is the SLOT SET, so this test names it rather than counting
        // envelopes.
        let world = TeamKeyWorld()
        let laptop = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        let secondMac = world.enrolDevice(uid: adminUid, deviceId: "device-admin-2", escrowKeyVersion: 4)
        world.seedMember(uid: adminUid, pins: [laptop.pin, secondMac.pin], role: "admin")
        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")

        let bootstrap = try await distributor.bootstrapTeamKeys(teamId: teamId)

        XCTAssertEqual(
            Set(bootstrap.envelopeIds),
            [
                "\(adminUid)_device-admin_1_v1",
                "\(adminUid)_device-admin_1_slug",
                "\(adminUid)_device-admin-2_4_v1",
                "\(adminUid)_device-admin-2_4_slug"
            ],
            "one envelope per device per slot, and no slot beyond v1 + slug"
        )

        // The slot set, read off the documents rather than off the ids, and the
        // self-addressing that makes the C-1 clause the one being satisfied.
        var publishedSlots: Set<String> = []
        for envelopeId in bootstrap.envelopeIds {
            let envelope = try world.envelope(id: envelopeId)
            publishedSlots.insert(try XCTUnwrap(envelope["keySlot"] as? String))
            XCTAssertEqual(envelope["uid"] as? String, adminUid, "self-addressed: d.uid == request.auth.uid")
            XCTAssertEqual(envelope["wrappedBy"] as? String, adminUid, "self-wrapped: coverage counts it")
        }
        XCTAssertEqual(
            publishedSlots,
            ["v1", "slug"],
            """
            C-1 permits a member self-wrap of the ACTIVE generation and the slug key only. \
            `createTeam` seeds activeKeyVersion == 1, so v1 and slug are exactly what is legal here; \
            any other slot in this set would be denied by firestore.rules.
            """
        )
        XCTAssertEqual(bootstrap.teamKeyVersion, 1, "the bootstrap publishes the generation the roster seeds")
    }

    func test_rotation_wraps_the_rotating_admins_own_devices_through_the_admin_path() async throws {
        // C-1's "PR 2 constraint", client side. `v(N+1)` is BY DEFINITION a
        // generation the roster has not published, so the self-wrap clause cannot
        // admit it — and the rotating admin is a member of their own team, so one
        // of the envelopes every rotation writes is self-addressed at exactly that
        // slot. `rotateTeamKey` therefore wraps its own Macs through the SAME
        // admin path it uses for everyone else (`wrapKeys` over `activeMemberUids`,
        // which includes `uid`), never through `selfWrapKeys`.
        //
        // WHAT THIS TEST CAN AND CANNOT PROVE. Both spellings emit a
        // byte-identical document, so no fake gateway can tell them apart; what
        // this pins is the document SHAPE the rules must admit — self-addressed,
        // self-wrapped, at `v(active + 1)`, for the rotator's every pinned device.
        // `test_the_rotating_admin_may_self_wrap_the_next_generation` in
        // `functions/scripts/test-firestore-rules.mjs` is the other half: it proves
        // the rules admit that shape for an ACTIVE ADMIN and deny it, identically
        // shaped, to a plain member. Neither test is worth much without the other.
        let world = TeamKeyWorld()
        let adminLaptop = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        let adminDesktop = world.enrolDevice(uid: adminUid, deviceId: "device-admin-2", escrowKeyVersion: 2)
        let joinerDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [adminLaptop.pin, adminDesktop.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [joinerDevice.pin])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        _ = try await distributor.rotateTeamKey(
            teamId: teamId,
            activeKeyVersion: 1,
            newKeyVersion: 2,
            activeMemberUids: [adminUid, joinerUid],
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-admin-path"
        )

        // EVERY pinned device of the rotator is covered, not just the Mac doing
        // the rotating — the "blind second Mac" this lane exists to prevent.
        for envelopeId in ["\(adminUid)_device-admin_1_v2", "\(adminUid)_device-admin-2_2_v2"] {
            let envelope = try world.envelope(id: envelopeId)
            XCTAssertEqual(envelope["uid"] as? String, adminUid)
            XCTAssertEqual(envelope["wrappedBy"] as? String, adminUid)
            XCTAssertEqual(
                envelope["keySlot"] as? String,
                "v2",
                "a self-addressed wrap of the generation ABOVE the roster's active one — legal only for an admin"
            )
        }
        // And the admin's own devices really can open it, so this is coverage
        // rather than a document that merely looks right.
        XCTAssertEqual(
            try adminDesktop.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(adminUid)_device-admin-2_2_v2"))),
            try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2))
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(world.callables.rotations.last).envelopeIds),
            [
                "\(adminUid)_device-admin_1_v2",
                "\(adminUid)_device-admin-2_2_v2",
                "\(joinerUid)_device-j_1_v2"
            ],
            "the rotator's own envelopes are handed to the callable as coverage like anyone else's"
        )
    }

    func test_a_promotion_landing_mid_rotation_aborts_retryably_without_burning_the_generation() async throws {
        // C-4. `rotateTeamKey`'s requirement set comes from a QUERY for active
        // members, and Firestore cannot conflict-detect a query — so a
        // `promoteTeamMember` landing between the scan and the commit used to add
        // an active member the rotation had required no wrap for and publish
        // `v(N+1)` over their head: active but blind, reached through membership
        // instead of key state. `membershipEpoch` on the team document is the read
        // a rotation CAN conflict-detect on, and the roster authority now refuses
        // with `aborted` (`functions/src/teamRosterState.ts:210-215`).
        //
        // That refusal reaches this client as a raw Firebase `NSError`. Two things
        // have to be true for it to be survivable, and both are asserted here:
        // it must arrive NAMED, so a caller can tell "retry me" from "give up";
        // and it must leave `v(N+1)` PENDING rather than promoted, or the retry
        // would mint a second generation whose envelopes could never replace the
        // first's immutable documents — the stranded-team failure, reached by a
        // race instead of by a crash.
        let world = TeamKeyWorld()
        let adminDevice = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        let joinerDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [adminDevice.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [joinerDevice.pin])

        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        world.callables.failNextRotation(
            with: NSError(
                domain: FunctionsErrorDomain,
                code: FunctionsErrorCode.aborted.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "This team's roster or key state changed while the call was in flight; retry against the current state."
                ]
            )
        )

        await assertThrows(.rosterStateMovedInFlight(teamId: teamId, operation: "rotateTeamKey")) {
            try await distributor.rotateTeamKey(
                teamId: self.teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [self.adminUid, self.joinerUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-epoch"
            )
        }

        // NOT PROMOTED, NOT DISCARDED. The generation stays pending, which is what
        // makes the retry publish the SAME key.
        XCTAssertNil(
            try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2)),
            "an aborted rotation must not promote a generation the roster never recorded"
        )
        let pendingV2 = try XCTUnwrap(try distributor.keyRing.pendingKey(teamId: teamId, slot: .vault(version: 2)))
        var firstAttemptWraps: [String: String] = [:]
        for envelopeId in world.envelopeIds() where envelopeId.hasSuffix("_v2") {
            firstAttemptWraps[envelopeId] = try world.envelope(id: envelopeId)["wrappedKeyBase64"] as? String
        }
        XCTAssertEqual(
            Set(firstAttemptWraps.keys),
            ["\(adminUid)_device-admin_1_v2", "\(joinerUid)_device-j_1_v2"],
            "the envelopes the refused attempt published stay on the server; they are create-only"
        )

        // The promotion that caused the abort: a third member is now active, and
        // the caller retries with a REFRESHED roster snapshot.
        let promotedUid = "pr2-promoted"
        let promotedDevice = world.enrolDevice(uid: promotedUid, deviceId: "device-p", escrowKeyVersion: 1)
        world.seedMember(uid: promotedUid, pins: [promotedDevice.pin])

        _ = try await distributor.rotateTeamKey(
            teamId: teamId,
            activeKeyVersion: 1,
            newKeyVersion: 2,
            activeMemberUids: [adminUid, joinerUid, promotedUid],
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-epoch"
        )

        XCTAssertEqual(
            try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2)),
            pendingV2,
            "the retry promoted the generation the FIRST attempt minted — a second one could never replace its envelopes"
        )
        for (envelopeId, wrapped) in firstAttemptWraps {
            XCTAssertEqual(
                try world.envelope(id: envelopeId)["wrappedKeyBase64"] as? String,
                wrapped,
                "the refused attempt's envelope \(envelopeId) was claimed, not rewritten"
            )
        }
        XCTAssertEqual(
            try promotedDevice.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(promotedUid)_device-p_1_v2"))),
            pendingV2,
            "the member promoted inside the window opens the SAME v2 everyone else holds"
        )
        XCTAssertEqual(world.callables.rotations.count, 2, "one refused attempt, one accepted retry")
        XCTAssertTrue(
            Set(world.callables.rotations[0].envelopeIds).isSubset(of: Set(world.callables.rotations[1].envelopeIds)),
            "the retry re-listed every envelope the refused attempt had claimed, plus the new member's"
        )
    }

    func test_a_non_abort_refusal_from_the_roster_authority_is_not_mistaken_for_a_stale_snapshot() async throws {
        // The mapping is a `guard`, and a guard that matched too widely would be
        // worse than none: C-3's `failed-precondition` means the member was
        // REMOVED mid-flight, and "retry against current state" is precisely the
        // live/removed re-join violation C-3 exists to stop. Anything that is not
        // `aborted` therefore reaches the caller untouched.
        let world = TeamKeyWorld()
        let adminDevice = world.enrolDevice(uid: adminUid, deviceId: "device-admin", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [adminDevice.pin], role: "admin")
        let distributor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try distributor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        // The code the comment names: C-3's `stillPendingMemberRef` re-read
        // throws `failed-precondition` when the member was REMOVED mid-flight.
        world.callables.failNextRotation(
            with: NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.failedPrecondition.rawValue)
        )

        do {
            _ = try await distributor.rotateTeamKey(
                teamId: teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [adminUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-denied"
            )
            XCTFail("expected the roster authority's refusal to surface")
        } catch let error as TeamVaultKeyDistributionError {
            XCTFail("a failed-precondition must not be renamed a stale snapshot: \(error)")
        } catch {
            XCTAssertEqual((error as NSError).code, FunctionsErrorCode.failedPrecondition.rawValue)
            XCTAssertEqual((error as NSError).domain, FunctionsErrorDomain)
        }
        XCTAssertNil(
            try distributor.keyRing.key(teamId: teamId, slot: .vault(version: 2)),
            "no refusal promotes the generation"
        )
    }

    // MARK: - Cross-admin rotation conflict (PR 2 review round 2, B4)

    func test_a_second_admin_refuses_to_claim_an_abandoned_rotations_envelope() async throws {
        // THE KEY FORK. The read-before-write claim predicate compares uid,
        // deviceId, escrowKeyVersion, keySlot and the pinned fingerprint — all
        // functions of the recipient's roster pin, none of which say WHICH KEY
        // the existing envelope wraps. For a retained generation that is fine:
        // every admin holds identical bytes. For the generation a rotation
        // MINTS it is catastrophic.
        //
        // Admin A mints K_A for v2, publishes one envelope and dies before the
        // callable, so the roster is still at v1 and K_A exists only in A's
        // Keychain. Admin B rotates, mints a DIFFERENT K_B, and — before this
        // guard — claimed A's envelope because all five fields matched, then
        // published K_B to everybody else. `rotateTeamKey` counts coverage and
        // never sees key bytes, so the fork was recorded as a clean rotation:
        // A would go on sealing facts under K_A while labelling them
        // `teamKeyVersion: 2`, which the rules accept because they check the
        // label. Nobody could read them, and no later rotation could repair it.
        let world = TeamKeyWorld()
        let ringA = InMemoryTeamVaultKeyRing()
        let ringB = InMemoryTeamVaultKeyRing()
        let secondAdminUid = "pr2-admin-b"

        let deviceA = world.enrolDevice(uid: adminUid, deviceId: "device-a", escrowKeyVersion: 1)
        let deviceB = world.enrolDevice(uid: secondAdminUid, deviceId: "device-b", escrowKeyVersion: 1)
        let joinerDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [deviceA.pin], role: "admin")
        world.seedMember(uid: secondAdminUid, pins: [deviceB.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [joinerDevice.pin])

        let adminA = world.distributor(uid: adminUid, deviceId: "device-a", keyRing: ringA)
        let adminB = world.distributor(uid: secondAdminUid, deviceId: "device-b", keyRing: ringB)
        try ringA.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try ringB.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        let members = [adminUid, secondAdminUid, joinerUid]

        // 1. A's snapshot of the roster is the two admins; it publishes their
        //    envelopes and then dies at the callable, so the roster is still at
        //    v1 and K_A exists only in A's Keychain.
        world.callables.failNextRotation(with: NSError(domain: "test-transport", code: -1009))
        do {
            _ = try await adminA.rotateTeamKey(
                teamId: teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [adminUid, secondAdminUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-a"
            )
            XCTFail("the transport failure must surface")
        } catch {
            XCTAssertEqual((error as NSError).domain, "test-transport")
        }
        XCTAssertEqual(
            Set(world.envelopeIds()),
            ["\(adminUid)_device-a_1_v2", "\(secondAdminUid)_device-b_1_v2"],
            "A published its own and B's envelopes before dying; the roster is still at v1"
        )
        XCTAssertNil(try ringA.key(teamId: teamId, slot: .vault(version: 2)), "v2 is not recorded, so it is not promoted")
        let keyA = try XCTUnwrap(try ringA.pendingKey(teamId: teamId, slot: .vault(version: 2)))

        // 2. B rotates. It cannot see A's Keychain, so it mints a DIFFERENT v2
        //    and walks into A's envelope on the first member.
        await assertThrows(
            .rotationConflict(
                slot: "v2",
                envelopeId: "\(adminUid)_device-a_1_v2",
                wrappedBy: adminUid
            )
        ) {
            try await adminB.rotateTeamKey(
                teamId: self.teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b"
            )
        }

        let keyB = try XCTUnwrap(try ringB.pendingKey(teamId: teamId, slot: .vault(version: 2)))
        XCTAssertNotEqual(keyB, keyA, "the two Macs really did mint different v2 keys — that is the fork being caught")
        XCTAssertEqual(
            Set(world.envelopeIds()),
            ["\(adminUid)_device-a_1_v2", "\(secondAdminUid)_device-b_1_v2"],
            "ZERO K_B envelopes: B stopped on the conflict instead of publishing its own key to the rest of the team"
        )
        for envelopeId in world.envelopeIds() {
            let envelope = try world.envelope(id: envelopeId)
            XCTAssertEqual(envelope["wrappedBy"] as? String, adminUid, "every published v2 envelope is still A's")
        }
        XCTAssertEqual(
            try deviceB.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(secondAdminUid)_device-b_1_v2"))),
            keyA,
            "B's own device still holds A's key, not the one B minted"
        )
        XCTAssertEqual(
            world.callables.rotations.count,
            1,
            "B never reached the callable, so the only attempt on record is A's refused one"
        )
        XCTAssertNil(try ringB.key(teamId: teamId, slot: .vault(version: 2)), "and nothing was promoted on B")

        // 3. A resuming still succeeds. The refusal must not cost the ORIGINAL
        //    rotation its resumability — that is the whole point of the pending
        //    slot, and requiring `wrappedBy == uid` for a ring-sourced slot
        //    would have broken it for the departed-admin recovery path too.
        let progress = try await adminA.rotateTeamKey(
            teamId: teamId,
            activeKeyVersion: 1,
            newKeyVersion: 2,
            activeMemberUids: members,
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-a-2"
        )
        XCTAssertEqual(progress, TeamCloudVaultRewrapProgress(scannedDocuments: 0, rewrappedDocuments: 0, skippedDocuments: 0))
        XCTAssertEqual(
            Set(world.envelopeIds()),
            [
                "\(adminUid)_device-a_1_v2",
                "\(secondAdminUid)_device-b_1_v2",
                "\(joinerUid)_device-j_1_v2"
            ]
        )
        XCTAssertEqual(world.callables.rotations.map(\.newKeyVersion), [2, 2], "A's refused attempt, then A's retry")
        XCTAssertEqual(try ringA.key(teamId: teamId, slot: .vault(version: 2)), keyA, "A promoted its own generation")
        XCTAssertEqual(
            try joinerDevice.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(joinerUid)_device-j_1_v2"))),
            keyA,
            "ONE v2 reached the whole team — K_B is nowhere on the server"
        )
    }

    func test_an_admin_still_claims_a_departed_admins_wrap_of_a_retained_generation() async throws {
        // The other half of the B4 ruling: the `wrappedBy` check applies ONLY to
        // a slot this pass minted. A retained generation is bytes every admin
        // already holds identically, and PR 1 amendment N-2 deliberately keeps a
        // departed admin's pre-departure wraps valid so a surviving admin can
        // finish the promote they started. Requiring `wrappedBy == uid` here
        // would have turned that recovery into a hard stop.
        let world = TeamKeyWorld()
        let joinerDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: joinerUid, pins: [joinerDevice.pin], status: "pending")
        world.seedMember(uid: departedUid, pins: [], role: "admin", status: "removed")

        // The departed admin's wrap of v1, already on the server, made from the
        // SAME retained key the surviving admin holds.
        let departedWrap = try CloudVaultCrypto.wrapVaultKey(
            world.teamVaultKeyV1,
            recipientPublicKey: joinerDevice.privateKey.publicKey.x963Representation
        )
        world.gateway.setDocumentData(
            [
                "teamId": teamId,
                "uid": joinerUid,
                "deviceId": "device-j",
                "escrowKeyVersion": 1,
                "keySlot": "v1",
                "algorithm": TeamVaultKeyDistributor.envelopeAlgorithm,
                "wrappedKeyBase64": departedWrap.base64EncodedString(),
                "recipientPublicKeyFingerprint": joinerDevice.pin.publicKeyFingerprint,
                "wrappedBy": departedUid
            ],
            at: "team_key_envelopes/\(teamId)/envelopes/\(joinerUid)_device-j_1_v1"
        )

        let survivor = world.distributor(uid: adminUid, deviceId: "device-admin")
        try survivor.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try survivor.keyRing.store(world.teamSlugKey, teamId: teamId, slot: .slug)

        let published = try await survivor.issueJoinerKeys(
            teamId: teamId,
            joinerUid: joinerUid,
            retainedKeyVersions: [1]
        )

        XCTAssertEqual(
            published.envelopeIds.sorted(),
            ["\(joinerUid)_device-j_1_slug", "\(joinerUid)_device-j_1_v1"],
            "the departed admin's v1 envelope is CLAIMED toward coverage, not refused"
        )
        XCTAssertEqual(
            try world.envelope(id: "\(joinerUid)_device-j_1_v1")["wrappedBy"] as? String,
            departedUid,
            "and it was left exactly as it was — envelopes are immutable"
        )
        XCTAssertEqual(world.callables.promotions.map(\.uid), [joinerUid])
    }

    // MARK: - Pre-scan, ring provenance and the escape hatch (PR 2 review round 3)

    func test_a_conflict_on_the_last_member_still_writes_nothing() async throws {
        // B5. The conflict used to be found only when the pass REACHED an
        // occupied id, and `activeMemberUids` is caller-supplied with no
        // ordering contract anywhere — PR 3/4 will plausibly build it from a
        // `Set<String>`, whose iteration order differs per process. So two
        // admins iterating the same roster in different orders each covered the
        // members the other had not reached yet before refusing, and v(N+1)
        // ended up carrying TWO keys: wedged for everybody, and the doc comment
        // and the operator-facing error text both claimed "nothing was written".
        //
        // Here the only occupied id belongs to the LAST member B walks. Under
        // the per-member loop that is two K_B envelopes written before the
        // refusal; under the pre-scan it is none.
        let world = TeamKeyWorld()
        let ringA = InMemoryTeamVaultKeyRing()
        let ringB = InMemoryTeamVaultKeyRing()
        let secondAdminUid = "pr2-admin-b"

        let deviceA = world.enrolDevice(uid: adminUid, deviceId: "device-a", escrowKeyVersion: 1)
        let deviceB = world.enrolDevice(uid: secondAdminUid, deviceId: "device-b", escrowKeyVersion: 1)
        let joinerDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [deviceA.pin], role: "admin")
        world.seedMember(uid: secondAdminUid, pins: [deviceB.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [joinerDevice.pin])

        let adminA = world.distributor(uid: adminUid, deviceId: "device-a", keyRing: ringA)
        let adminB = world.distributor(uid: secondAdminUid, deviceId: "device-b", keyRing: ringB)
        try ringA.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try ringB.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))

        // A's snapshot happened to be the joiner alone, and A died at the
        // callable: exactly ONE v2 envelope exists, and it is the LAST id in B's
        // iteration order.
        world.callables.failNextRotation(with: NSError(domain: "test-transport", code: -1009))
        do {
            _ = try await adminA.rotateTeamKey(
                teamId: teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [joinerUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-a"
            )
            XCTFail("the transport failure must surface")
        } catch {
            XCTAssertEqual((error as NSError).domain, "test-transport")
        }
        XCTAssertEqual(world.envelopeIds(), ["\(joinerUid)_device-j_1_v2"])

        await assertThrows(
            .rotationConflict(
                slot: "v2",
                envelopeId: "\(joinerUid)_device-j_1_v2",
                wrappedBy: adminUid
            )
        ) {
            try await adminB.rotateTeamKey(
                teamId: self.teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [self.adminUid, secondAdminUid, self.joinerUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b"
            )
        }

        XCTAssertEqual(
            world.envelopeIds(),
            ["\(joinerUid)_device-j_1_v2"],
            "the two members B reached BEFORE the conflict got no envelope: the pass pre-scanned every id first"
        )
        XCTAssertEqual(
            try joinerDevice.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(joinerUid)_device-j_1_v2"))),
            try XCTUnwrap(try ringA.pendingKey(teamId: teamId, slot: .vault(version: 2))),
            "and the one envelope that exists still carries A's key, untouched"
        )
        XCTAssertEqual(world.callables.rotations.count, 1, "B never reached the callable")
    }

    func test_a_generation_the_roster_never_recorded_lands_pending_not_active() async throws {
        // B6, half one. `loadKeyRingFromEnvelopes` is the launch-time key
        // pickup, and an abandoned rotation's envelopes are exactly what it
        // finds: v(N+1) documents no callable ever confirmed. Storing those in
        // the ACTIVE ring made "active" mean "some admin wrapped this for me"
        // instead of "the team published this", which is a different claim and a
        // weaker one. The roster decides.
        let world = TeamKeyWorld()
        world.seedTeam(
            activeKeyVersion: 2,
            retainedKeyVersions: [1, 2],
            slugKeyId: try CloudVaultCrypto.vaultKeyID(for: world.teamSlugKey)
        )
        let device = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: joinerUid, pins: [device.pin])
        world.seedMember(uid: adminUid, pins: [], role: "admin")

        for (slot, key) in [("v1", world.teamVaultKeyV1), ("v2", world.teamVaultKeyV2), ("v3", world.teamVaultKeyV3), ("slug", world.teamSlugKey)] {
            try world.seedEnvelope(
                id: "\(joinerUid)_device-j_1_\(slot)",
                uid: joinerUid,
                deviceId: "device-j",
                escrowKeyVersion: 1,
                keySlot: slot,
                fingerprint: device.pin.publicKeyFingerprint,
                wrappedBy: adminUid,
                key: key,
                recipientPublicKey: device.publicKeyBase64
            )
        }

        let joiner = TeamVaultKeyDistributor(
            gateway: world.gateway,
            uid: joinerUid,
            deviceId: "device-j",
            keyRing: InMemoryTeamVaultKeyRing(),
            callables: world.callables,
            escrowPrivateKey: device
        )
        let loaded = try await joiner.loadKeyRingFromEnvelopes(teamId: teamId)

        XCTAssertEqual(
            Set(loaded),
            [.vault(version: 1), .vault(version: 2), .vault(version: 3), .slug],
            "every openable envelope is still picked up — nothing this device can read is thrown away"
        )
        // Recorded by the roster -> ACTIVE.
        XCTAssertEqual(try joiner.keyRing.key(teamId: teamId, slot: .vault(version: 1)), world.teamVaultKeyV1)
        XCTAssertEqual(try joiner.keyRing.key(teamId: teamId, slot: .vault(version: 2)), world.teamVaultKeyV2)
        XCTAssertEqual(try joiner.keyRing.key(teamId: teamId, slot: .slug), world.teamSlugKey)
        // NOT recorded — an abandoned rotation's generation -> PENDING only.
        XCTAssertNil(
            try joiner.keyRing.key(teamId: teamId, slot: .vault(version: 3)),
            "the roster records v1 and v2; v3 is a generation no callable confirmed"
        )
        XCTAssertEqual(try joiner.keyRing.pendingKey(teamId: teamId, slot: .vault(version: 3)), world.teamVaultKeyV3)
    }

    func test_an_active_ring_entry_cannot_switch_off_the_minted_generation_guard() async throws {
        // B6, half two, and the mutation this kills is a one-liner: restoring
        // `mintedInThisPass = minted.isPending ? [newSlot] : []` makes this pass.
        //
        // The ring here holds v2 ACTIVE — the state the old
        // `loadKeyRingFromEnvelopes` produced from an abandoned rotation's
        // envelope. The guard must NOT read that as "the roster confirmed v2, so
        // any admin's wrap of it is mine to claim": the roster still records v1,
        // and the other members' v2 ids may be occupied by a wrap of a key this
        // Mac has never seen. Whether a generation is minted-in-this-pass is a
        // fact about the ROSTER, not about this Keychain.
        let world = TeamKeyWorld()
        let ringB = InMemoryTeamVaultKeyRing()
        let secondAdminUid = "pr2-admin-b"

        let deviceA = world.enrolDevice(uid: adminUid, deviceId: "device-a", escrowKeyVersion: 1)
        let deviceB = world.enrolDevice(uid: secondAdminUid, deviceId: "device-b", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [deviceA.pin], role: "admin")
        world.seedMember(uid: secondAdminUid, pins: [deviceB.pin], role: "admin")

        // A's abandoned v2, addressed to A's own device.
        try world.seedEnvelope(
            id: "\(adminUid)_device-a_1_v2",
            uid: adminUid,
            deviceId: "device-a",
            escrowKeyVersion: 1,
            keySlot: "v2",
            fingerprint: deviceA.pin.publicKeyFingerprint,
            wrappedBy: adminUid,
            key: world.teamVaultKeyV2,
            recipientPublicKey: deviceA.publicKeyBase64
        )

        try ringB.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try ringB.store(world.teamVaultKeyV2, teamId: teamId, slot: .vault(version: 2))
        let adminB = world.distributor(uid: secondAdminUid, deviceId: "device-b", keyRing: ringB)

        await assertThrows(
            .rotationConflict(slot: "v2", envelopeId: "\(adminUid)_device-a_1_v2", wrappedBy: adminUid)
        ) {
            try await adminB.rotateTeamKey(
                teamId: self.teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: [self.adminUid, secondAdminUid],
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b"
            )
        }
        XCTAssertEqual(
            world.envelopeIds(),
            ["\(adminUid)_device-a_1_v2"],
            "B published nothing over A's abandoned generation, ACTIVE ring entry or not"
        )
        XCTAssertTrue(world.callables.rotations.isEmpty)
    }

    func test_a_burned_generation_is_abandoned_server_side_and_the_team_rotates_past_it() async throws {
        // B7, and the whole B4 scenario carried to an ENDING. Until now a team
        // that hit `rotationConflict` had nowhere to go: the client refuses
        // anything but `active + 1`, the callable refuses it too, and `active + 1`
        // is precisely the generation A occupied and only A can finish. The
        // shipped error text told the operator to "rotate again from the
        // generation the roster still records", which is the same v2 — an
        // instruction the code rejects.
        //
        // The escape hatch is real and it is server side: burn v2 on the roster,
        // then mint v3. A's v2 envelopes are left exactly where they are, which
        // is safe because `firestore.rules` pins every fact write to the
        // roster's ACTIVE version, so no document can ever name v2.
        let world = TeamKeyWorld()
        let ringA = InMemoryTeamVaultKeyRing()
        let ringB = InMemoryTeamVaultKeyRing()
        let secondAdminUid = "pr2-admin-b"

        let deviceA = world.enrolDevice(uid: adminUid, deviceId: "device-a", escrowKeyVersion: 1)
        let deviceB = world.enrolDevice(uid: secondAdminUid, deviceId: "device-b", escrowKeyVersion: 1)
        let joinerDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [deviceA.pin], role: "admin")
        world.seedMember(uid: secondAdminUid, pins: [deviceB.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [joinerDevice.pin])

        let adminA = world.distributor(uid: adminUid, deviceId: "device-a", keyRing: ringA)
        let adminB = world.distributor(uid: secondAdminUid, deviceId: "device-b", keyRing: ringB)
        try ringA.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try ringB.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        let members = [adminUid, secondAdminUid, joinerUid]

        // 1. A mints K_A, covers the whole team, and dies at the callable.
        world.callables.failNextRotation(with: NSError(domain: "test-transport", code: -1009))
        do {
            _ = try await adminA.rotateTeamKey(
                teamId: teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-a"
            )
            XCTFail("the transport failure must surface")
        } catch {
            XCTAssertEqual((error as NSError).domain, "test-transport")
        }
        let keyA = try XCTUnwrap(try ringA.pendingKey(teamId: teamId, slot: .vault(version: 2)))
        let abandonedEnvelopeIds = Set(world.envelopeIds())
        XCTAssertEqual(abandonedEnvelopeIds.count, 3)

        // 2. A never comes back. B refuses to claim v2 — correctly — and is
        //    stuck, because v2 is the only version anyone is allowed to mint.
        await assertThrows(
            .rotationConflict(slot: "v2", envelopeId: "\(adminUid)_device-a_1_v2", wrappedBy: adminUid)
        ) {
            try await adminB.rotateTeamKey(
                teamId: self.teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b"
            )
        }
        await assertThrows(.rotationNotSequential(active: 1, expected: 2, requested: 3)) {
            try await adminB.rotateTeamKey(
                teamId: self.teamId,
                activeKeyVersion: 1,
                newKeyVersion: 3,
                activeMemberUids: members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b"
            )
        }

        // 3. The way out. Burn v2 on the roster, then rotate to v3.
        let progress = try await adminB.abandonConflictingGenerationAndRotate(
            teamId: teamId,
            conflictingVersion: 2,
            activeKeyVersion: 1,
            activeMemberUids: members,
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-b-2"
        )

        XCTAssertEqual(
            world.callables.abandonments,
            [RecordingTeamRosterCallables.Abandonment(teamId: teamId, version: 2)],
            "v2 is burned by the roster authority — the client cannot write that field"
        )
        XCTAssertEqual(
            world.callables.rotations.map(\.newKeyVersion),
            [2, 3],
            "A's refused v2 attempt, then B's v3 — B never re-attempted v2"
        )
        XCTAssertEqual(progress, TeamCloudVaultRewrapProgress(scannedDocuments: 0, rewrappedDocuments: 0, skippedDocuments: 0))

        let keyB = try XCTUnwrap(try ringB.key(teamId: teamId, slot: .vault(version: 3)))
        XCTAssertNotEqual(keyB, keyA)
        XCTAssertNil(
            try ringB.pendingKey(teamId: teamId, slot: .vault(version: 2)),
            "the burned generation's pending key is destroyed: it can open nothing that will ever exist"
        )

        // A's v2 envelopes are untouched and A's key never reached anybody new.
        for envelopeId in abandonedEnvelopeIds {
            XCTAssertEqual(try world.envelope(id: envelopeId)["wrappedBy"] as? String, adminUid)
        }
        XCTAssertEqual(
            Set(world.envelopeIds()),
            abandonedEnvelopeIds.union([
                "\(adminUid)_device-a_1_v3",
                "\(secondAdminUid)_device-b_1_v3",
                "\(joinerUid)_device-j_1_v3"
            ])
        )
        XCTAssertEqual(
            try joinerDevice.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(joinerUid)_device-j_1_v3"))),
            keyB,
            "ONE v3 reached the whole team"
        )
        XCTAssertEqual(
            try deviceB.unwrapTeamKey(world.wrappedKey(in: try world.envelope(id: "\(secondAdminUid)_device-b_1_v3"))),
            keyB
        )
    }

    // MARK: - The recovery's own retry (PR 2 review round 4, B8)

    /// The B4/B7 deadlock, seeded once: admin A minted `v2`, covered the whole
    /// team, died at the callable and never came back, so the only version
    /// anybody is allowed to mint is occupied by wraps of a key only A's
    /// Keychain holds. Admin B holds `v1` and is stuck. Three round-4 cases
    /// start from exactly this state.
    private struct StuckOnAnAbandonedGeneration {
        let world: TeamKeyWorld
        let adminB: TeamVaultKeyDistributor
        let ringB: InMemoryTeamVaultKeyRing
        let secondAdminUid: String
        let members: [String]
        let joinerDevice: TestEscrowDevice
        let keyA: Data
        let abandonedEnvelopeIds: Set<String>
    }

    private func stuckOnAnAbandonedGeneration() async throws -> StuckOnAnAbandonedGeneration {
        let world = TeamKeyWorld()
        let ringA = InMemoryTeamVaultKeyRing()
        let ringB = InMemoryTeamVaultKeyRing()
        let secondAdminUid = "pr2-admin-b"

        let deviceA = world.enrolDevice(uid: adminUid, deviceId: "device-a", escrowKeyVersion: 1)
        let deviceB = world.enrolDevice(uid: secondAdminUid, deviceId: "device-b", escrowKeyVersion: 1)
        let joinerDevice = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: adminUid, pins: [deviceA.pin], role: "admin")
        world.seedMember(uid: secondAdminUid, pins: [deviceB.pin], role: "admin")
        world.seedMember(uid: joinerUid, pins: [joinerDevice.pin])

        let adminA = world.distributor(uid: adminUid, deviceId: "device-a", keyRing: ringA)
        let adminB = world.distributor(uid: secondAdminUid, deviceId: "device-b", keyRing: ringB)
        try ringA.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try ringB.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        let members = [adminUid, secondAdminUid, joinerUid]

        world.callables.failNextRotation(with: NSError(domain: "test-transport", code: -1009))
        do {
            _ = try await adminA.rotateTeamKey(
                teamId: teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-a"
            )
            XCTFail("the transport failure must surface")
        } catch {
            XCTAssertEqual((error as NSError).domain, "test-transport")
        }
        return StuckOnAnAbandonedGeneration(
            world: world,
            adminB: adminB,
            ringB: ringB,
            secondAdminUid: secondAdminUid,
            members: members,
            joinerDevice: joinerDevice,
            keyA: try XCTUnwrap(try ringA.pendingKey(teamId: teamId, slot: .vault(version: 2))),
            abandonedEnvelopeIds: Set(world.envelopeIds())
        )
    }

    /// The `v3` envelope ids one full rotation over this team publishes.
    private func generationEnvelopeIds(_ stuck: StuckOnAnAbandonedGeneration, version: Int) -> Set<String> {
        [
            "\(adminUid)_device-a_1_v\(version)",
            "\(stuck.secondAdminUid)_device-b_1_v\(version)",
            "\(joinerUid)_device-j_1_v\(version)"
        ]
    }

    func test_a_second_press_of_the_recovery_burns_nothing_new_and_only_rotates() async throws {
        // B8. The recovery is TWO server calls — burn v2, then rotate to v3 —
        // and the doc comment, the operator-facing error text and PR-body known
        // risk 11 all promise that a plain retry RESUMES from a crash between
        // them. It did not. The method re-derived the version to burn from
        // `activeKeyVersion` + `burnedKeyVersions` on every call, so on the
        // second press — with v2 now legitimately in `burnedKeyVersions`,
        // exactly as the doc instructs the caller to refresh it — the
        // derivation returned v3 and the "retry" burned the generation this Mac
        // had just minted. Two of a hard-capped 100 versions per press,
        // permanently, with nothing surfacing the spend.
        let stuck = try await stuckOnAnAbandonedGeneration()
        let world = stuck.world

        // B refuses to claim A's v2, and the refusal NAMES the generation. That
        // name is what the recovery is handed; nothing is re-derived from the
        // roster's arithmetic (round 4 ruling (c)).
        var conflictingVersion: Int?
        do {
            _ = try await stuck.adminB.rotateTeamKey(
                teamId: teamId,
                activeKeyVersion: 1,
                newKeyVersion: 2,
                activeMemberUids: stuck.members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b"
            )
            XCTFail("v2 carries A's key, not B's")
        } catch let error as TeamVaultKeyDistributionError {
            guard case .rotationConflict(let slot, _, _) = error else {
                XCTFail("expected a rotationConflict, got \(error)")
                return
            }
            conflictingVersion = Int(slot.dropFirst())
        }
        XCTAssertEqual(conflictingVersion, 2, "the conflict carries the slot the recovery must burn")

        // Press 1: the burn lands, v3's envelopes are published, and then the
        // rotation callable refuses. Nothing about this is exotic — the inner
        // `rotateTeamKey` publishes every envelope BEFORE it calls.
        world.callables.failNextRotation(
            with: NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.failedPrecondition.rawValue)
        )
        do {
            _ = try await stuck.adminB.abandonConflictingGenerationAndRotate(
                teamId: teamId,
                conflictingVersion: try XCTUnwrap(conflictingVersion),
                activeKeyVersion: 1,
                activeMemberUids: stuck.members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b-1"
            )
            XCTFail("the callable's refusal must surface")
        } catch {
            XCTAssertEqual(FunctionsErrorCode(rawValue: (error as NSError).code), .failedPrecondition)
        }
        let pendingV3 = try XCTUnwrap(try stuck.ringB.pendingKey(teamId: teamId, slot: .vault(version: 3)))

        // Press 2, with the roster's REFRESHED burn list — precisely what the
        // doc comment tells the operator to do.
        let progress = try await stuck.adminB.abandonConflictingGenerationAndRotate(
            teamId: teamId,
            conflictingVersion: 2,
            activeKeyVersion: 1,
            burnedKeyVersions: [2],
            activeMemberUids: stuck.members,
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-b-2"
        )
        XCTAssertEqual(progress, TeamCloudVaultRewrapProgress(scannedDocuments: 0, rewrappedDocuments: 0, skippedDocuments: 0))

        XCTAssertEqual(
            world.callables.abandonments,
            [RecordingTeamRosterCallables.Abandonment(teamId: teamId, version: 2)],
            "ONE burn, of the generation the conflict named — the second press burns nothing new"
        )
        XCTAssertEqual(
            world.callables.rotations.map(\.newKeyVersion),
            [2, 3, 3],
            "A's dead v2, B's refused v3, then B's retry of THE SAME v3 — never a v4"
        )
        XCTAssertEqual(
            try stuck.ringB.key(teamId: teamId, slot: .vault(version: 3)),
            pendingV3,
            "the retry resumes the pending generation instead of minting a second one"
        )
        XCTAssertNotEqual(pendingV3, stuck.keyA)
        XCTAssertEqual(
            Set(world.envelopeIds()),
            stuck.abandonedEnvelopeIds.union(generationEnvelopeIds(stuck, version: 3)),
            "zero extra generations consumed: A's three v2 envelopes and B's three v3 envelopes, nothing else"
        )
        XCTAssertEqual(
            try stuck.joinerDevice.unwrapTeamKey(
                world.wrappedKey(in: try world.envelope(id: "\(joinerUid)_device-j_1_v3"))
            ),
            pendingV3,
            "ONE v3 reached the whole team, and it is the key press 1 minted"
        )
    }

    func test_an_aborted_rotation_after_the_burn_retries_the_rotation_only() async throws {
        // B8, the ORDINARY ending. `rosterStateMovedInFlight` is the C-4 abort
        // the design documents as retryable, and it lands after the burn and
        // after v3's envelopes are published. Under the re-deriving code the
        // operator's retry satisfied every server precondition — v3 was not
        // active, not retained, the next unclaimed version, and its envelopes
        // existed BECAUSE THIS MAC HAD JUST WRITTEN THEM — so v3 was burned and
        // v4 minted. Every press of the button cost two generations.
        let stuck = try await stuckOnAnAbandonedGeneration()
        let world = stuck.world

        world.callables.failNextRotation(
            with: NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.aborted.rawValue)
        )
        await assertThrows(.rosterStateMovedInFlight(teamId: teamId, operation: "rotateTeamKey")) {
            try await stuck.adminB.abandonConflictingGenerationAndRotate(
                teamId: self.teamId,
                conflictingVersion: 2,
                activeKeyVersion: 1,
                activeMemberUids: stuck.members,
                rewrapWorker: world.rewrapWorker(),
                rewrapJobId: "job-b-1"
            )
        }
        let pendingV3 = try XCTUnwrap(try stuck.ringB.pendingKey(teamId: teamId, slot: .vault(version: 3)))
        let afterTheAbort = Set(world.envelopeIds())

        // The retry is a ROTATION retry. The burn already landed; re-running it
        // is neither needed nor allowed to cost a second generation.
        _ = try await stuck.adminB.abandonConflictingGenerationAndRotate(
            teamId: teamId,
            conflictingVersion: 2,
            activeKeyVersion: 1,
            burnedKeyVersions: [2],
            activeMemberUids: stuck.members,
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-b-2"
        )

        XCTAssertEqual(
            world.callables.abandonments,
            [RecordingTeamRosterCallables.Abandonment(teamId: teamId, version: 2)],
            "the retry after an aborted rotation burns nothing"
        )
        XCTAssertEqual(world.callables.rotations.map(\.newKeyVersion), [2, 3, 3])
        XCTAssertEqual(
            try stuck.ringB.key(teamId: teamId, slot: .vault(version: 3)),
            pendingV3,
            "the same pending key the aborted pass minted, promoted by the retry"
        )
        XCTAssertNil(try stuck.ringB.key(teamId: teamId, slot: .vault(version: 4)))
        XCTAssertEqual(
            Set(world.envelopeIds()),
            afterTheAbort,
            "the retry claimed its own v3 envelopes rather than publishing a fresh generation's"
        )
        XCTAssertEqual(
            afterTheAbort,
            stuck.abandonedEnvelopeIds.union(generationEnvelopeIds(stuck, version: 3))
        )
    }

    func test_the_recovery_burns_the_version_the_conflict_named_not_the_next_rotatable_one() async throws {
        // Round 4 ruling (c), isolated from any particular failure mode. By the
        // time the operator re-presses the button for the v2 conflict the
        // roster has burned v2 (this recovery's own first press) AND v3 (a
        // second admin's abandoned attempt).
        // `nextRotatableKeyVersion(active: 1, burned: [2, 3])` is 4, so the old
        // re-deriving code would have asked the roster authority to burn v4 — a
        // generation nobody has minted and no envelope exists for. The version
        // to burn is the ARGUMENT the conflict named, it is already burned, and
        // so nothing is burned at all.
        let stuck = try await stuckOnAnAbandonedGeneration()
        let world = stuck.world

        let progress = try await stuck.adminB.abandonConflictingGenerationAndRotate(
            teamId: teamId,
            conflictingVersion: 2,
            activeKeyVersion: 1,
            burnedKeyVersions: [2, 3],
            activeMemberUids: stuck.members,
            rewrapWorker: world.rewrapWorker(),
            rewrapJobId: "job-b-3"
        )
        XCTAssertEqual(progress, TeamCloudVaultRewrapProgress(scannedDocuments: 0, rewrappedDocuments: 0, skippedDocuments: 0))

        XCTAssertEqual(world.callables.abandonments, [], "v2 is already burned, and v4 was never this recovery's to burn")
        XCTAssertEqual(
            world.callables.rotations.map(\.newKeyVersion),
            [2, 4],
            "A's dead v2, then the first version past every burn the roster records"
        )
        XCTAssertNotNil(try stuck.ringB.key(teamId: teamId, slot: .vault(version: 4)))
        XCTAssertEqual(
            Set(world.envelopeIds()),
            stuck.abandonedEnvelopeIds.union(generationEnvelopeIds(stuck, version: 4))
        )
    }

    // MARK: - Rewrap across generations (PR 2 review B2 / N1 / N6)

    func test_the_rewrap_reaches_a_fact_from_every_retained_generation() async throws {
        // Two ordinary interruptions are enough to spread a corpus over three
        // generations: a rotation N -> N+1 dies mid-collection, a second
        // departure raises `keyRotationRequired`, and an admin rotates
        // N+1 -> N+2. A worker that assumed "old = new - 1" would reach the
        // first fact still at vN, fail to open it and abort the whole pass —
        // after the callable had already recorded N+2, so those facts would be
        // un-rewrappable AND, because the rules pin writes to the active
        // version, unwritable. For ever.
        let world = TeamKeyWorld()
        let unheldKey = TeamKeyWorld.randomKey()
        try world.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        try world.keyRing.store(world.teamVaultKeyV2, teamId: teamId, slot: .vault(version: 2))

        let seeds: [(String, Data, Int)] = [
            ("gen-1", world.teamVaultKeyV1, 1),
            ("gen-2", world.teamVaultKeyV2, 2),
            ("gen-3", world.teamVaultKeyV3, 3),
            ("gen-9", unheldKey, 9)
        ]
        var docIDs: [String: String] = [:]
        for (label, keyData, version) in seeds {
            let docID = try CloudVaultCrypto.pensieveSlugHmac(
                "team-memory-fact:\(teamId):\(label)",
                keyData: world.teamSlugKey
            )
            docIDs[label] = docID
            try world.seedTeamFact(docID: docID, body: Data(label.utf8), keyData: keyData, teamKeyVersion: version)
        }

        let progress = try await world.rewrapWorker().runRewrap(
            teamId: teamId,
            jobId: "job-generations",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV3,
            newTeamKeyVersion: 3
        )

        // v1 and v2 are re-sealed; v3 is already current; v9 is a generation
        // this device never received an envelope for, so it is COUNTED and the
        // pass carries on instead of stranding everything behind it.
        XCTAssertEqual(
            progress,
            TeamCloudVaultRewrapProgress(scannedDocuments: 4, rewrappedDocuments: 2, skippedDocuments: 1)
        )
        XCTAssertFalse(progress.isComplete)
        XCTAssertNil(
            world.completions.completedRewrap(teamId: teamId),
            "a pass that skipped a fact has NOT completed the re-key, and must not claim it did"
        )

        for label in ["gen-1", "gen-2", "gen-3"] {
            let docID = try XCTUnwrap(docIDs[label])
            let fact = try XCTUnwrap(world.gateway.documentData(at: "team_memory_facts/\(teamId)/facts/\(docID)"))
            XCTAssertEqual(fact["teamKeyVersion"] as? Int, 3, "\(label) must end at the active generation")
            let aad = try CloudVaultAADContext(
                uid: "team:\(teamId)",
                collection: "team_memory_facts",
                docID: docID,
                field: "sealedMemory"
            )
            let envelope = try XCTUnwrap(CloudVaultCrypto.decodeBlobEnvelope(from: fact["sealedMemory"]))
            XCTAssertEqual(
                try CloudVaultCrypto.openBlob(envelope, keyData: world.teamVaultKeyV3, aadContext: aad),
                Data(label.utf8)
            )
        }
        let strandedID = try XCTUnwrap(docIDs["gen-9"])
        let stranded = try XCTUnwrap(world.gateway.documentData(at: "team_memory_facts/\(teamId)/facts/\(strandedID)"))
        XCTAssertEqual(stranded["teamKeyVersion"] as? Int, 9, "an unopenable fact is left exactly as it was")

        // Once the missing generation arrives, the same pass finishes the job
        // and — only then — records completion.
        try world.keyRing.store(unheldKey, teamId: teamId, slot: .vault(version: 9))
        let finishing = try await world.rewrapWorker().runRewrap(
            teamId: teamId,
            jobId: "job-generations-2",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV3,
            newTeamKeyVersion: 3
        )
        XCTAssertEqual(
            finishing,
            TeamCloudVaultRewrapProgress(scannedDocuments: 4, rewrappedDocuments: 1, skippedDocuments: 0)
        )
        XCTAssertEqual(
            world.completions.completedRewrap(teamId: teamId),
            TeamRewrapCompletion(jobId: "job-generations-2", teamKeyVersion: 3),
            "the completion marker is what lets the next cycle tell 'done' from 'never ran' — the roster cannot, because rotateTeamKey clears keyRotationRequired before a single fact is re-sealed"
        )
    }

    // MARK: - Rotation completeness is a ROSTER fact (PR 4, promoting PR 2 review N1)

    func test_a_completed_rewrap_is_published_to_the_roster_for_every_member() async throws {
        // PR 2 recorded completion in `UserDefaults`, which answers only "did
        // THIS Mac finish the pass". "Has this team's corpus been re-keyed" is a
        // TEAM question, and the next admin to pick the job up is on a different
        // Mac. PR 4 promotes it to a roster field written by an admin-only
        // callable — `firestore.rules` still says `allow write: if false` on
        // `team_rosters/{teamId}`, so the field is server-written by
        // construction and no client can claim a rotation it never ran.
        let world = TeamKeyWorld()
        try world.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        let docID = try CloudVaultCrypto.pensieveSlugHmac(
            "team-memory-fact:\(teamId):published",
            keyData: world.teamSlugKey
        )
        try world.seedTeamFact(
            docID: docID,
            body: Data("published".utf8),
            keyData: world.teamVaultKeyV1,
            teamKeyVersion: 1
        )

        let progress = try await world.rewrapWorker(publishToRoster: true).runRewrap(
            teamId: teamId,
            jobId: "job-published",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV2,
            newTeamKeyVersion: 2
        )

        XCTAssertTrue(progress.isComplete)
        // The LOCAL note is still written. It is the only thing that answers
        // "is the next pass on this machine a resume" when the network is down,
        // so the promotion adds a publisher rather than replacing the store.
        XCTAssertEqual(
            world.completions.completedRewrap(teamId: teamId),
            TeamRewrapCompletion(jobId: "job-published", teamKeyVersion: 2)
        )
        XCTAssertEqual(
            world.callables.rewrapCompletions,
            [
                RecordingTeamRosterCallables.RewrapCompletion(
                    teamId: teamId,
                    keyVersion: 2,
                    rewrapJobId: "job-published"
                )
            ]
        )
    }

    func test_a_pass_that_skipped_a_fact_publishes_no_roster_completion() async throws {
        // The whole point of the marker: a rotation whose corpus is only
        // partly re-keyed must not look finished to any member. The roster
        // cannot tell on its own — `rotateTeamKey` clears `keyRotationRequired`
        // and advances `activeKeyVersion` before a single fact is re-sealed.
        let world = TeamKeyWorld()
        let unheldKey = TeamKeyWorld.randomKey()
        try world.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        for (label, keyData, version) in [
            ("held", world.teamVaultKeyV1, 1),
            ("unheld", unheldKey, 9)
        ] as [(String, Data, Int)] {
            let docID = try CloudVaultCrypto.pensieveSlugHmac(
                "team-memory-fact:\(teamId):\(label)",
                keyData: world.teamSlugKey
            )
            try world.seedTeamFact(
                docID: docID,
                body: Data(label.utf8),
                keyData: keyData,
                teamKeyVersion: version
            )
        }

        let progress = try await world.rewrapWorker(publishToRoster: true).runRewrap(
            teamId: teamId,
            jobId: "job-partial",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV2,
            newTeamKeyVersion: 2
        )

        XCTAssertEqual(progress.skippedDocuments, 1)
        XCTAssertFalse(progress.isComplete)
        XCTAssertNil(world.completions.completedRewrap(teamId: teamId))
        XCTAssertTrue(
            world.callables.rewrapCompletions.isEmpty,
            "a partial pass must not stamp the roster with a completion every member would read as done"
        )
    }

    func test_the_rewrap_pages_past_the_first_batch() async throws {
        // The pass walks by document id with `whereDocumentID(isGreaterThan:)`.
        // Every existing case seeded ONE fact against `batchLimit: 2`, so the
        // second iteration never ran — and an ineffective cursor would not fail
        // loudly, it would SPIN: every document in the re-fetched page is
        // skipped by the already-current guard, so the page never shrinks below
        // the limit and the last id never advances.
        let world = TeamKeyWorld()
        try world.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        for index in 0..<5 {
            let docID = try CloudVaultCrypto.pensieveSlugHmac(
                "team-memory-fact:\(teamId):page-\(index)",
                keyData: world.teamSlugKey
            )
            try world.seedTeamFact(
                docID: docID,
                body: Data("page-\(index)".utf8),
                keyData: world.teamVaultKeyV1,
                teamKeyVersion: 1
            )
        }

        let progress = try await world.rewrapWorker(batchLimit: 2).runRewrap(
            teamId: teamId,
            jobId: "job-pages",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV2,
            newTeamKeyVersion: 2
        )

        XCTAssertEqual(
            progress,
            TeamCloudVaultRewrapProgress(scannedDocuments: 5, rewrappedDocuments: 5, skippedDocuments: 0),
            "every fact is visited exactly once across three pages, and the loop terminates"
        )
        let facts = world.gateway.documents(under: "team_memory_facts/\(teamId)/facts")
        XCTAssertEqual(facts.count, 5)
        XCTAssertTrue(facts.values.allSatisfy { $0["teamKeyVersion"] as? Int == 2 })
    }

    func test_the_rewrap_opens_a_generation_the_roster_recorded_but_this_mac_never_promoted() async throws {
        // PR 2 review round 2, flag 2. `rotateTeamKey` promotes v(N+1) from
        // pending to active only AFTER the callable returns. If that Keychain
        // write throws, the roster records N+1 while this Mac holds it only as
        // pending — and the NEXT rotation's rewrap would reach every fact this
        // pass re-sealed at N+1, find no active slot, and count the entire
        // corpus into `skippedDocuments` for ever. The lookup therefore falls
        // back to the pending slot and says so in the log.
        let world = TeamKeyWorld()
        try world.keyRing.store(world.teamVaultKeyV1, teamId: teamId, slot: .vault(version: 1))
        // v2 was recorded by the roster but never promoted here.
        try world.keyRing.storePending(world.teamVaultKeyV2, teamId: teamId, slot: .vault(version: 2))
        XCTAssertNil(try world.keyRing.key(teamId: teamId, slot: .vault(version: 2)))

        let docID = try CloudVaultCrypto.pensieveSlugHmac(
            "team-memory-fact:\(teamId):stranded",
            keyData: world.teamSlugKey
        )
        try world.seedTeamFact(docID: docID, body: Data("stranded".utf8), keyData: world.teamVaultKeyV2, teamKeyVersion: 2)

        let progress = try await world.rewrapWorker().runRewrap(
            teamId: teamId,
            jobId: "job-unpromoted",
            keyRing: world.keyRing,
            newKeyData: world.teamVaultKeyV3,
            newTeamKeyVersion: 3
        )

        XCTAssertEqual(
            progress,
            TeamCloudVaultRewrapProgress(scannedDocuments: 1, rewrappedDocuments: 1, skippedDocuments: 0),
            "a failed promotion must not strand the corpus it already re-sealed"
        )
        XCTAssertTrue(progress.isComplete)
        let fact = try XCTUnwrap(world.gateway.documentData(at: "team_memory_facts/\(teamId)/facts/\(docID)"))
        XCTAssertEqual(fact["teamKeyVersion"] as? Int, 3)
        let aad = try CloudVaultAADContext(
            uid: "team:\(teamId)",
            collection: "team_memory_facts",
            docID: docID,
            field: "sealedMemory"
        )
        let envelope = try XCTUnwrap(CloudVaultCrypto.decodeBlobEnvelope(from: fact["sealedMemory"]))
        XCTAssertEqual(
            try CloudVaultCrypto.openBlob(envelope, keyData: world.teamVaultKeyV3, aadContext: aad),
            Data("stranded".utf8)
        )
    }

    // MARK: - Unwrap authority (PR 2 review N3)

    func test_the_key_ring_refuses_an_envelope_no_admin_wrapped_or_this_device_pins() async throws {
        // Decrypting proves only that the wrap was made for THIS device's escrow
        // key. It does not say who made it. `firestore.rules` confines envelope
        // `create` to an active admin or a self-wrap; the client mirrors that,
        // so a rules bypass or a compromised backend cannot plant a key this
        // device would then seal every future fact under.
        let world = TeamKeyWorld()
        world.seedTeam(slugKeyId: try CloudVaultCrypto.vaultKeyID(for: world.teamSlugKey))
        let device = world.enrolDevice(uid: joinerUid, deviceId: "device-j", escrowKeyVersion: 1)
        world.seedMember(uid: joinerUid, pins: [device.pin])
        world.seedMember(uid: adminUid, pins: [], role: "admin")
        world.seedMember(uid: departedUid, pins: [], role: "member")

        let joiner = TeamVaultKeyDistributor(
            gateway: world.gateway,
            uid: joinerUid,
            deviceId: "device-j",
            keyRing: InMemoryTeamVaultKeyRing(),
            callables: world.callables,
            escrowPrivateKey: device
        )

        // (1) Wrapped by a plain member. Perfectly decryptable, and refused.
        try world.seedEnvelope(
            id: "\(joinerUid)_device-j_1_v1",
            uid: joinerUid,
            deviceId: "device-j",
            escrowKeyVersion: 1,
            keySlot: "v1",
            fingerprint: device.pin.publicKeyFingerprint,
            wrappedBy: departedUid,
            key: world.teamVaultKeyV1,
            recipientPublicKey: device.publicKeyBase64
        )
        // (2) Wrapped by the admin, but naming a fingerprint this device's own
        // roster row does not pin.
        try world.seedEnvelope(
            id: "\(joinerUid)_device-j_2_v2",
            uid: joinerUid,
            deviceId: "device-j",
            escrowKeyVersion: 2,
            keySlot: "v2",
            fingerprint: "Zm9yZ2VkLWZpbmdlcnByaW50LWZvcmdlZC1maW5nZXJwcmk=",
            wrappedBy: adminUid,
            key: world.teamVaultKeyV2,
            recipientPublicKey: device.publicKeyBase64
        )

        let refused = try await joiner.loadKeyRingFromEnvelopes(teamId: teamId)
        XCTAssertEqual(refused, [])
        XCTAssertNil(try joiner.keyRing.key(teamId: teamId, slot: .vault(version: 1)))
        XCTAssertNil(try joiner.keyRing.key(teamId: teamId, slot: .vault(version: 2)))

        // (3) The same slot wrapped twice by the admin, under two escrow
        // generations the roster pins to the same published key. The HIGHER
        // generation wins, deterministically — not whichever document the query
        // happened to return last.
        world.seedMember(uid: joinerUid, pins: [
            device.pin,
            TeamEscrowDevicePin(deviceId: "device-j", escrowKeyVersion: 4, publicKeyFingerprint: device.pin.publicKeyFingerprint)
        ])
        try world.seedEnvelope(
            id: "\(joinerUid)_device-j_1_slug",
            uid: joinerUid,
            deviceId: "device-j",
            escrowKeyVersion: 1,
            keySlot: "slug",
            fingerprint: device.pin.publicKeyFingerprint,
            wrappedBy: adminUid,
            key: world.teamVaultKeyV1,
            recipientPublicKey: device.publicKeyBase64
        )
        try world.seedEnvelope(
            id: "\(joinerUid)_device-j_4_slug",
            uid: joinerUid,
            deviceId: "device-j",
            escrowKeyVersion: 4,
            keySlot: "slug",
            fingerprint: device.pin.publicKeyFingerprint,
            wrappedBy: adminUid,
            key: world.teamSlugKey,
            recipientPublicKey: device.publicKeyBase64
        )

        let accepted = try await joiner.loadKeyRingFromEnvelopes(teamId: teamId)
        XCTAssertEqual(accepted, [.slug])
        XCTAssertEqual(
            try joiner.keyRing.key(teamId: teamId, slot: .slug),
            world.teamSlugKey,
            "the newest escrow generation's envelope is the one that lands"
        )
    }

    // MARK: - Helpers

    private func assertThrows<T>(
        _ expected: TeamVaultKeyDistributionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as TeamVaultKeyDistributionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

// MARK: - Test doubles

/// In-memory stand-in for the Keychain ring. The production ring is
/// `KeychainTeamVaultKeyRing`; a unit test must not write Keychain items.
final class InMemoryTeamVaultKeyRing: TeamVaultKeyRing, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private var pending: [String: Data] = [:]

    func key(teamId: String, slot: TeamKeySlot) throws -> Data? {
        lock.withLock { keys[Self.account(teamId, slot)] }
    }

    func store(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws {
        lock.withLock { keys[Self.account(teamId, slot)] = keyData }
    }

    func pendingKey(teamId: String, slot: TeamKeySlot) throws -> Data? {
        lock.withLock { pending[Self.account(teamId, slot)] }
    }

    func storePending(_ keyData: Data, teamId: String, slot: TeamKeySlot) throws {
        lock.withLock { pending[Self.account(teamId, slot)] = keyData }
    }

    func promotePendingKey(teamId: String, slot: TeamKeySlot) throws {
        lock.withLock {
            guard let promoted = pending[Self.account(teamId, slot)] else { return }
            keys[Self.account(teamId, slot)] = promoted
        }
    }

    func deletePendingKey(teamId: String, slot: TeamKeySlot) throws {
        lock.withLock { pending[Self.account(teamId, slot)] = nil }
    }

    private static func account(_ teamId: String, _ slot: TeamKeySlot) -> String {
        "\(teamId)#\(slot.rawValue)"
    }
}

/// Captures the local rewrap-completion note instead of writing `UserDefaults`,
/// so a test can assert that only a CLEAN pass records one.
final class RecordingTeamRewrapCompletions: TeamRewrapCompletionRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: TeamRewrapCompletion] = [:]

    func completedRewrap(teamId: String) -> TeamRewrapCompletion? {
        lock.withLock { records[teamId] }
    }

    func recordCompletedRewrap(_ completion: TeamRewrapCompletion, teamId: String) {
        lock.withLock { records[teamId] = completion }
    }
}

/// Records the roster callables instead of calling them, so a test can assert
/// WHAT was published and IN WHAT ORDER relative to the envelope writes.
final class RecordingTeamRosterCallables: TeamRosterCallableInvoking, @unchecked Sendable {
    struct Promotion: Equatable {
        let teamId: String
        let uid: String
        let envelopeIds: [String]
    }

    struct Rotation: Equatable {
        let teamId: String
        let newKeyVersion: Int
        let envelopeIds: [String]
    }

    struct Abandonment: Equatable {
        let teamId: String
        let version: Int
    }

    /// The roster-side completion stamp (PR 4). Recorded, so a test can assert
    /// that a pass which SKIPPED a document publishes nothing.
    struct RewrapCompletion: Equatable {
        let teamId: String
        let keyVersion: Int
        let rewrapJobId: String
    }

    private let lock = NSLock()
    private var recordedPromotions: [Promotion] = []
    private var recordedRotations: [Rotation] = []
    private var recordedAbandonments: [Abandonment] = []
    private var queuedRotationErrors: [Error] = []
    private var recordedCompletions: [RewrapCompletion] = []

    var promotions: [Promotion] { lock.withLock { recordedPromotions } }
    /// Every generation the roster authority was asked to BURN, in order.
    var abandonments: [Abandonment] { lock.withLock { recordedAbandonments } }
    /// EVERY rotation ATTEMPT, refused ones included — a refusal that publishes
    /// the same envelope ids as the retry is the property the C-4 test asserts.
    var rotations: [Rotation] { lock.withLock { recordedRotations } }
    var rewrapCompletions: [RewrapCompletion] { lock.withLock { recordedCompletions } }

    /// Make the next `rotateTeamKey` call record its attempt and then throw.
    /// Queued, so one test can model "refused, then accepted on retry".
    func failNextRotation(with error: Error) {
        lock.withLock { queuedRotationErrors.append(error) }
    }

    func promoteTeamMember(teamId: String, uid: String, envelopeIds: [String]) async throws {
        lock.withLock { recordedPromotions.append(Promotion(teamId: teamId, uid: uid, envelopeIds: envelopeIds)) }
    }

    func rotateTeamKey(teamId: String, newKeyVersion: Int, envelopeIds: [String]) async throws {
        let failure: Error? = lock.withLock {
            recordedRotations.append(Rotation(teamId: teamId, newKeyVersion: newKeyVersion, envelopeIds: envelopeIds))
            return queuedRotationErrors.isEmpty ? nil : queuedRotationErrors.removeFirst()
        }
        if let failure {
            throw failure
        }
    }

    func abandonTeamKeyGeneration(teamId: String, version: Int) async throws {
        lock.withLock { recordedAbandonments.append(Abandonment(teamId: teamId, version: version)) }
    }

    func recordTeamRewrapComplete(teamId: String, keyVersion: Int, rewrapJobId: String) async throws {
        lock.withLock {
            recordedCompletions.append(
                RewrapCompletion(teamId: teamId, keyVersion: keyVersion, rewrapJobId: rewrapJobId)
            )
        }
    }
}

/// One enrolled escrow device: a real P-256 key agreement keypair, its pinned
/// fingerprint, and the ability to open wraps made for it. Real crypto, because
/// "the wrong device cannot open this envelope" is the property under test.
struct TestEscrowDevice: TeamEscrowPrivateKeyProviding, @unchecked Sendable {
    let privateKey: P256.KeyAgreement.PrivateKey
    let pin: TeamEscrowDevicePin

    var publicKeyBase64: String { privateKey.publicKey.x963Representation.base64EncodedString() }

    func unwrapTeamKey(_ wrapped: Data) throws -> Data {
        try CloudVaultCrypto.unwrapVaultKey(wrapped, privateKey: privateKey)
    }
}

/// Seeded world: a fake Firestore, a shared key ring, recording callables, and
/// the three keys a team lives on.
final class TeamKeyWorld: @unchecked Sendable {
    let teamId = "team_0123456789abcdef"
    let gateway = CloudSyncFirestoreFakeGateway()
    let keyRing = InMemoryTeamVaultKeyRing()
    let callables = RecordingTeamRosterCallables()
    let completions = RecordingTeamRewrapCompletions()

    let teamVaultKeyV1: Data
    let teamVaultKeyV2: Data
    let teamVaultKeyV3: Data
    let teamSlugKey: Data

    init() {
        // Real 32-byte AES keys, generated without touching the Keychain: the
        // properties under test are about WHICH key reaches WHICH device, so the
        // keys have to be distinct and real, but they need no secure storage.
        self.teamVaultKeyV1 = TeamKeyWorld.randomKey()
        self.teamVaultKeyV2 = TeamKeyWorld.randomKey()
        self.teamVaultKeyV3 = TeamKeyWorld.randomKey()
        self.teamSlugKey = TeamKeyWorld.randomKey()
    }

    static func randomKey() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    /// `keyRing` defaults to the world's shared ring. Pass a separate one to
    /// model TWO ADMINS ON TWO MACS — the B4 case, where each holds its own
    /// Keychain and neither can see the other's pending generation.
    func distributor(uid: String, deviceId: String, keyRing: TeamVaultKeyRing? = nil) -> TeamVaultKeyDistributor {
        TeamVaultKeyDistributor(
            gateway: gateway,
            uid: uid,
            deviceId: deviceId,
            keyRing: keyRing ?? self.keyRing,
            callables: callables,
            escrowPrivateKey: TestEscrowDevice(
                privateKey: P256.KeyAgreement.PrivateKey(),
                pin: TeamEscrowDevicePin(deviceId: deviceId, escrowKeyVersion: 1, publicKeyFingerprint: "")
            )
        )
    }

    func rewrapWorker(batchLimit: Int = 2, publishToRoster: Bool = false) -> TeamCloudVaultRewrapWorker {
        TeamCloudVaultRewrapWorker(
            gateway: gateway,
            batchLimit: batchLimit,
            completionRecorder: completions,
            completionPublisher: publishToRoster
                ? TeamRosterCallableCompletionPublisher(callables: callables)
                : nil
        )
    }

    @discardableResult
    func enrolDevice(uid: String, deviceId: String, escrowKeyVersion: Int) -> TestEscrowDevice {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.x963Representation
        let fingerprint = Data(SHA256.hash(data: publicKeyData)).base64EncodedString()
        let device = TestEscrowDevice(
            privateKey: privateKey,
            pin: TeamEscrowDevicePin(
                deviceId: deviceId,
                escrowKeyVersion: escrowKeyVersion,
                publicKeyFingerprint: fingerprint
            )
        )
        seedEscrowPublicKey(
            uid: uid,
            deviceId: deviceId,
            escrowKeyVersion: escrowKeyVersion,
            publicKeyBase64: publicKeyData.base64EncodedString(),
            fingerprint: fingerprint
        )
        return device
    }

    func seedEscrowPublicKey(
        uid: String,
        deviceId: String,
        escrowKeyVersion: Int,
        publicKeyBase64: String,
        fingerprint: String
    ) {
        gateway.setDocumentData(
            [
                "deviceId": deviceId,
                "keyVersion": escrowKeyVersion,
                "publicKeyData": publicKeyBase64,
                "publicKeyFingerprint": fingerprint,
                "algorithm": "ECIES-P256-AESGCM"
            ],
            at: "users/\(uid)/escrow_public_keys/\(deviceId)_\(escrowKeyVersion)"
        )
    }

    /// The team document the roster authority owns.
    ///
    /// Only ``TeamVaultKeyDistributor/loadKeyRingFromEnvelopes(teamId:)`` reads
    /// it, and only to decide which slots the ROSTER has recorded (PR 2 review
    /// round 3, B6). A test that does not seed it models a client that cannot
    /// read the team document, in which case nothing is promoted to the active
    /// ring — the safe direction.
    func seedTeam(
        activeKeyVersion: Int = 1,
        retainedKeyVersions: [Int] = [1],
        burnedKeyVersions: [Int] = [],
        slugKeyId: String? = nil
    ) {
        var document: [String: Any] = [
            "teamId": teamId,
            "activeKeyVersion": activeKeyVersion,
            "retainedKeyVersions": retainedKeyVersions,
            "burnedKeyVersions": burnedKeyVersions,
            "keyRotationRequired": false,
            "schemaVersion": 1
        ]
        if let slugKeyId { document["slugKeyId"] = slugKeyId }
        gateway.setDocumentData(document, at: "team_rosters/\(teamId)")
    }

    func seedMember(uid: String, pins: [TeamEscrowDevicePin], role: String = "member", status: String = "active") {
        gateway.setDocumentData(
            [
                "uid": uid,
                "teamId": teamId,
                "role": role,
                "status": status,
                "escrowDeviceFingerprints": pins.map {
                    [
                        "deviceId": $0.deviceId,
                        "keyVersion": $0.escrowKeyVersion,
                        "publicKeyFingerprint": $0.publicKeyFingerprint
                    ] as [String: Any]
                }
            ],
            at: "team_rosters/\(teamId)/members/\(uid)"
        )
    }

    func seedTeamFact(
        docID: String,
        body: Data,
        keyData: Data,
        teamKeyVersion: Int,
        updatedAt: Date = Date(timeIntervalSince1970: 1_770_000_000)
    ) throws {
        let aad = try CloudVaultAADContext(
            uid: "team:\(teamId)",
            collection: "team_memory_facts",
            docID: docID,
            field: "sealedMemory"
        )
        let sealed = try CloudVaultCrypto.sealBlob(
            body,
            keyData: keyData,
            keyVersion: teamKeyVersion,
            aadContext: aad
        )
        gateway.setDocumentData(
            [
                "uid": "pr2-admin",
                "teamId": teamId,
                "docID": docID,
                "schemaVersion": 2,
                "sourceKind": "agent",
                "kind": "architecture",
                "reviewStatus": "approved",
                "sealedMemory": try CloudVaultCrypto.firestoreDictionary(sealed),
                "sourceRefHmacs": ["a"],
                "citationCount": 1,
                "validFrom": updatedAt,
                "updatedAt": updatedAt,
                "replicatedAt": updatedAt,
                "teamKeyVersion": teamKeyVersion
            ],
            at: "team_memory_facts/\(teamId)/facts/\(docID)"
        )
    }

    /// Write an envelope document directly, wrapping `key` to `recipientPublicKey`
    /// with real ECIES so the negative cases are "this WOULD have decrypted, and
    /// was refused anyway" rather than "the bytes were garbage".
    func seedEnvelope(
        id: String,
        uid: String,
        deviceId: String,
        escrowKeyVersion: Int,
        keySlot: String,
        fingerprint: String,
        wrappedBy: String,
        key: Data,
        recipientPublicKey: String
    ) throws {
        guard let publicKeyData = Data(base64Encoded: recipientPublicKey) else {
            throw TeamVaultKeyDistributionError.malformedEnvelope(envelopeId: id)
        }
        let wrapped = try CloudVaultCrypto.wrapVaultKey(key, recipientPublicKey: publicKeyData)
        gateway.setDocumentData(
            [
                "teamId": teamId,
                "uid": uid,
                "deviceId": deviceId,
                "escrowKeyVersion": escrowKeyVersion,
                "keySlot": keySlot,
                "algorithm": "ECIES-P256-AESGCM",
                "wrappedKeyBase64": wrapped.base64EncodedString(),
                "recipientPublicKeyFingerprint": fingerprint,
                "wrappedBy": wrappedBy
            ],
            at: "team_key_envelopes/\(teamId)/envelopes/\(id)"
        )
    }

    func envelopeIds() -> [String] {
        gateway.documents(under: "team_key_envelopes/\(teamId)/envelopes")
            .keys
            .map { String($0.split(separator: "/").last ?? "") }
    }

    func envelope(id: String) throws -> [String: Any] {
        guard let data = gateway.documentData(at: "team_key_envelopes/\(teamId)/envelopes/\(id)") else {
            throw TeamVaultKeyDistributionError.malformedEnvelope(envelopeId: id)
        }
        return data
    }

    func wrappedKey(in envelope: [String: Any]) -> Data {
        guard let base64 = envelope["wrappedKeyBase64"] as? String,
              let data = Data(base64Encoded: base64) else {
            return Data()
        }
        return data
    }
}
