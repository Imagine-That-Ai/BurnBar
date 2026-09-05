# Team Memory Design — Roster Authority, Envelope, and the Two Semantics We Cannot Hide

**Status:** Design specification for review, 2026-09-05  
**Context:** Packet P20 / Deliverable D16 of the revised Memory Program ([`docs/superpowers/plans/2026-09-05-memory-program-revised.md`](../plans/2026-09-05-memory-program-revised.md), Section D16; handoff packet in [`docs/superpowers/plans/2026-09-05-memory-program-handoff.md`](../plans/2026-09-05-memory-program-handoff.md)).  
**Preceding specifications:** [Memory Pro Models (PR #2501)](2026-09-02-memory-pro-models-design.md), [Memory Blind Sync (PR #2519)](2026-09-03-memory-blind-sync-design.md).  
**Companion implementation PRs:** Packet P21 (D16 PR 1: roster authority + rules) and Packet P22 (D16 PR 2: team envelope + client).  

---

## 1. Goal and Non-Goals

### 1.1 Goal
Extend BurnBar's zero-knowledge memory architecture so that members of a recognized team or organization can contribute and synchronize approved project memories into a shared team space—without granting BurnBar servers, infrastructure, or operators access to the plaintext facts, embeddings, citations, or encryption keys.

### 1.2 Non-Goals
- **No client-asserted membership:** Clients cannot grant themselves or other users team membership.
- **No server-side key escrow or proxy decryption:** The server never holds, computes, or unwraps a team vault key or member vault key.
- **No server-side semantic search over team memory:** Recall and semantic ranking over team memories happen entirely client-side inside the local SQLite/vector store after local decryption.
- **No silent auto-sharing:** Private memories and unreviewed candidate facts never sync to team space.
- **No cryptographic erasure of already-replicated data upon member departure:** As detailed in §6, client-side replication means departing members retain local data; rotation protects future writes only.

---

## 2. Roster Authority: Who Writes the Roster and Under What Rules

### 2.1 The Current Terrain and Its Trust Boundary
Today, every cryptographic escrow and data-vault construct in OpenBurnBar is strictly intra-account:
- Paths: `users/{userId}/escrow_devices`, `users/{userId}/escrow_public_keys`, `users/{userId}/escrow_envelopes`, `users/{userId}/escrow_grants`, and `users/{userId}/memory_facts`.
- Protection: Every collection is guarded by `ownsUserNamespace(userId)` (`firestore.rules:15, 1402, 2644-2646, 3467-3470`).
- Key publication: Device cross-certification (`SessionLogSyncService+VaultKeyPublishing.swift:25-60`) operates strictly among devices belonging to the same authenticated `uid`.

In this single-user model, user authorization is synonymous with user namespace ownership. For multi-user team memory, this assumption breaks down. **No client can assert team membership.** If a client could write to a team roster or attach a team claim to their own profile, an attacker could inject themselves into any team's memory space or arbitrarily revoke peers.

### 2.2 The Named Server-Side Writer: `TeamRosterService`
To maintain a strict security boundary, team roster state is managed exclusively by an authoritative server-side writer:
- **Service Name:** `TeamRosterService`
- **Implementation:** Firebase Cloud Functions running with Firebase Admin SDK credentials (`functions/src/teamRoster.ts`).
- **Callable Entrypoints:**
  - `createTeam(name, billingAccountId)`: Creates team entity and assigns caller as `admin`.
  - `inviteTeamMember(teamId, inviteeEmail, role)`: Emits an authenticated cryptographic invitation token.
  - `acceptTeamInvite(inviteToken, escrowPublicKey)`: Validates invite, stores the member's escrow public key, and enrolls them as `active`.
  - `removeTeamMember(teamId, targetUid)`: Changes member status to `removed`, logs audit trail, and flags team for key rotation.
  - `rotateTeamKey(teamId, newKeyVersion, encryptedEnvelopes)`: Stores re-wrapped team key envelopes for all active members.
- **Authority Grounding:** Membership mutations must be grounded in:
  1. Verified team administrator credentials (`role == "admin"` in `team_rosters/{teamId}/members/{auth.uid}`).
  2. Verified billing seat entitlement (Stripe or Enterprise organization billing status via `stripeWithResilience`).
  3. Strict server-side rate limits and immutable audit log appending (`team_rosters/{teamId}/audit_log`).

### 2.3 Roster Document Schema
Roster records are partitioned into a top-level collection `team_rosters`:

#### Team Document: `team_rosters/{teamId}`
```json
{
  "teamId": "team_abc123",
  "orgId": "org_xyz789",
  "name": "Platform Engineering",
  "activeKeyVersion": 1,
  "keyRotationRequired": false,
  "createdAt": "2026-09-05T12:00:00Z",
  "updatedAt": "2026-09-05T12:00:00Z"
}
```

#### Member Document: `team_rosters/{teamId}/members/{uid}`
```json
{
  "uid": "user_456",
  "teamId": "team_abc123",
  "role": "member",
  "status": "active",
  "escrowPublicKey": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...",
  "escrowKeyVersion": 1,
  "activeTeamKeyVersion": 1,
  "joinedAt": "2026-09-05T12:00:00Z",
  "invitedBy": "user_admin_001",
  "updatedAt": "2026-09-05T12:00:00Z"
}
```

### 2.4 Firestore Security Rules on Roster
Client SDK writes to `team_rosters` are blocked unconditionally:
```javascript
match /team_rosters/{teamId} {
  // Members can read team metadata
  allow read: if request.auth != null 
    && exists(/databases/$(database)/documents/team_rosters/$(teamId)/members/$(request.auth.uid))
    && get(/databases/$(database)/documents/team_rosters/$(teamId)/members/$(request.auth.uid)).data.status == "active";

  // NO client may write directly to team metadata
  allow write: if false;

  match /members/{memberUid} {
    // A member can read their own membership or the full roster of teams they belong to
    allow read: if request.auth != null 
      && (request.auth.uid == memberUid || (
        exists(/databases/$(database)/documents/team_rosters/$(teamId)/members/$(request.auth.uid))
        && get(/databases/$(database)/documents/team_rosters/$(teamId)/members/$(request.auth.uid)).data.status == "active"
      ));

    // NO client may modify membership or roles directly
    allow write: if false;
  }
}
```

---

## 3. `team_memory_facts` Collection Schema & Security Rules

### 3.1 Collection Path
Team memories reside in a dedicated top-level hierarchy:
`/team_memory_facts/{teamId}/facts/{docID}`

This path mirrors the structure of `/users/{userId}/memory_facts/{memoryDocId}`, maintaining parity between personal and team sync engines while establishing a clean separation of authorization context.

### 3.2 Document Schema
Every team fact document contains opaque routing metadata, provenance attribution, and the encrypted ciphertext envelope:

```json
{
  "uid": "user_456",
  "teamId": "team_abc123",
  "docID": "5a2f8b...",
  "schemaVersion": 2,
  "sourceKind": "agent",
  "kind": "architecture",
  "reviewStatus": "approved",
  "sealedMemory": {
    "schemaVersion": 2,
    "algorithm": "AES-256-GCM",
    "keyVersion": 1,
    "nonce": "kM9...",
    "ciphertext": "p7T...",
    "tag": "8x1...",
    "aad": "OpenBurnBar-CloudVault-aad-v2|team:team_abc123|team_memory_facts|5a2f8b...|sealedMemory|2|sealedMemory"
  },
  "sourceRefHmacs": ["a1b2...", "c3d4..."],
  "citationCount": 2,
  "validFrom": "2026-09-05T12:00:00Z",
  "updatedAt": "2026-09-05T12:00:00Z",
  "replicatedAt": "2026-09-05T12:00:00Z",
  "teamKeyVersion": 1
}
```

### 3.3 Security Rules Implementation
```javascript
match /team_memory_facts/{teamId}/facts/{docID} {
  function isTeamMember(teamId) {
    return request.auth != null
      && exists(/databases/$(database)/documents/team_rosters/$(teamId)/members/$(request.auth.uid))
      && get(/databases/$(database)/documents/team_rosters/$(teamId)/members/$(request.auth.uid)).data.status == "active";
  }

  function isTeamAdmin(teamId) {
    return isTeamMember(teamId)
      && get(/databases/$(database)/documents/team_rosters/$(teamId)/members/$(request.auth.uid)).data.role == "admin";
  }

  function cloudVaultTeamAADContext(teamId, collection, docID, field) {
    return "OpenBurnBar-CloudVault-aad-v2|team:" + teamId + "|" + collection + "|" + docID + "|" + field + "|2|" + field;
  }

  function validTeamMemoryFactKeys() {
    return request.resource.data.keys().hasOnly([
      "uid",
      "teamId",
      "docID",
      "schemaVersion",
      "sourceKind",
      "kind",
      "reviewStatus",
      "sealedMemory",
      "sourceRefHmacs",
      "citationCount",
      "validFrom",
      "updatedAt",
      "replicatedAt",
      "teamKeyVersion",
      "rewrapJobId"
    ]);
  }

  // READ: Only active team members with an active Data Vault entitlement may read facts
  allow read: if isTeamMember(teamId)
    && hasActiveDataVaultEntitlement(request.auth.uid);

  // CREATE / UPDATE: Active team members can publish facts under strict schema constraints
  allow create, update: if isTeamMember(teamId)
    && hasActiveDataVaultEntitlement(request.auth.uid)
    && validTeamMemoryFactKeys()
    && request.resource.data.uid == request.auth.uid
    && request.resource.data.teamId == teamId
    && request.resource.data.docID == docID
    && validMemoryOpaqueId(docID)
    // Anti-leakage: No plaintext fields permitted
    && !("text" in request.resource.data)
    && !("body" in request.resource.data)
    && !("citations" in request.resource.data)
    && !("vector" in request.resource.data)
    && !("cloakedVector" in request.resource.data)
    && !("embedding" in request.resource.data)
    // Metadata shape validation
    && request.resource.data.schemaVersion is int
    && request.resource.data.schemaVersion >= 2
    && request.resource.data.sourceKind in ["chat", "agent"]
    && request.resource.data.kind in ["fact", "preference", "event", "profile", "relationship", "other", "decision", "architecture", "procedure", "gotcha", "todo"]
    && request.resource.data.reviewStatus == "approved"
    // Ciphertext and Team AAD validation
    && validCloudSealedBlob(
      request.resource.data.sealedMemory,
      cloudVaultTeamAADContext(teamId, "team_memory_facts", docID, "sealedMemory")
    )
    && request.resource.data.sealedMemory.schemaVersion >= 2
    && validMemorySourceRefHmacs(request.resource.data.sourceRefHmacs)
    && request.resource.data.citationCount is int
    && request.resource.data.citationCount >= 0
    && request.resource.data.citationCount <= 50
    && request.resource.data.validFrom is timestamp
    && request.resource.data.updatedAt is timestamp
    && request.resource.data.replicatedAt is timestamp
    && request.resource.data.teamKeyVersion is int
    && request.resource.data.teamKeyVersion >= 1;

  // DELETE: A member may delete their own contributed facts; team admins may delete any fact
  allow delete: if (isTeamMember(teamId) && request.auth.uid == resource.data.uid)
    || isTeamAdmin(teamId);
}
```

### 3.4 Red-Team Adversarial Cases
The following security test cases must be asserted in rules unit tests:

| Test Case Identifier | Adversarial Action | Expected Result | Enforcement Mechanism |
|---|---|---|---|
| `RED-TEAM-01` | Non-member user attempts to `get()` or `list()` facts in `/team_memory_facts/{teamId}/facts` | **DENIED** (403 Permission Denied) | `isTeamMember(teamId)` returns false (`!exists` in roster). |
| `RED-TEAM-02` | Non-member user attempts to `create` a fact in `/team_memory_facts/{teamId}/facts` | **DENIED** (403 Permission Denied) | `isTeamMember(teamId)` returns false. |
| `RED-TEAM-03` | Active team member attempts to forge author UID (`request.resource.data.uid != request.auth.uid`) | **DENIED** | `request.resource.data.uid == request.auth.uid` assertion fails. |
| `RED-TEAM-04` | Active member attempts to write unencrypted fact (includes `"body"` or `"text"` or `"embedding"`) | **DENIED** | Negated key presence checks fail closed. |
| `RED-TEAM-05` | Removed ex-member attempts to read team facts using a cached auth token | **DENIED** | Member status check `get(member).data.status == "active"` fails immediately. |
| `RED-TEAM-06` | Attacker copies valid ciphertext from `teamA` into `teamB` | **DENIED** (Rules) or **DECRYPT FAIL** (Client) | Rules reject if AAD doesn't match `teamB`. If attacker tampers with outer AAD to say `teamB`, AES-GCM tag verification fails during decryption. |
| `RED-TEAM-07` | Client attempts to add self to `team_rosters/{teamId}/members/{uid}` | **DENIED** | `allow write: if false` on `team_rosters`. |
| `RED-TEAM-08` | Active member attempts to publish an unapproved fact (`reviewStatus: "quarantined"`) | **DENIED** | `request.resource.data.reviewStatus == "approved"` required. |
| `RED-TEAM-09` | Active member lacks Data Vault entitlement tier | **DENIED** | `hasActiveDataVaultEntitlement` returns false. |
| `RED-TEAM-10` | Write specifies mismatched `teamId` between path and body | **DENIED** | `request.resource.data.teamId == teamId` assertion fails. |

---

## 4. Team-Bound AAD and Doc-ID Derivation

### 4.1 Binding `teamId` in the Additional Authenticated Data (AAD)
In the CloudVault AES-256-GCM envelope, the AAD is cryptographically authenticated by the GCM tag. If ciphertext is moved to another document or collection, tag verification fails fail-closed.

For team facts, the AAD string explicitly binds the `teamId`:
```
cloudVaultTeamAADContext(teamId, collection, docID, field) =
  "OpenBurnBar-CloudVault-aad-v2|team:" + teamId + "|" + collection + "|" + docID + "|" + field + "|2|" + field
```

**Concrete example:**
```
OpenBurnBar-CloudVault-aad-v2|team:team_eng_core|team_memory_facts|7f9a1c8d0e|sealedMemory|2|sealedMemory
```

#### Why Binding `teamId` is Cryptographically Mandatory
1. **Cross-Tenant Splice Prevention:** Even if two teams share the same underlying fact or identical plaintext inputs, a ciphertext encrypted for Team A cannot be injected into Team B.
2. **Personal-to-Team Splice Prevention:** A ciphertext from a user's personal vault (`users/{uid}/memory_facts`) cannot be re-uploaded directly to team memory without local decryption and re-sealing under the team key. The personal AAD contains `userId`, whereas the team AAD contains `team:teamId`. Any attempt to cross-post raw ciphertext causes AES-GCM tag verification failure.

### 4.2 Team-Bound Doc-ID Derivation
The document ID in Firestore must be deterministic for identical facts within a team (to prevent duplicate documents) while remaining completely opaque to the server.

The doc-ID is derived using HMAC-SHA256 with the team vault key:
```swift
let slugInput = "team-memory-fact:\(teamId):\(cloudIdentity ?? memoryID)"
let docID = try CloudVaultCrypto.pensieveSlugHmac(slugInput, keyData: teamVaultKey)
```

#### Properties
- **Collision Resistance Across Teams:** Incorporating `\(teamId)` into the HMAC pre-image ensures that if two distinct teams happen to generate identical memory IDs, their Firestore `docID` values remain completely disjoint.
- **Server Blindness:** The server cannot reverse the HMAC or determine which client-side memory or project generated the document ID.

---

## 5. Per-Member Consent and Contribution Matrix

### 5.1 The Cardinal Principle
> **Consent is a client-side display and contribution control, NOT a cryptographic confidentiality boundary.**

Once a memory fact is encrypted under the team key and uploaded to `team_memory_facts`, **any authorized team member possessing the team key can decrypt and read it**. Turning off team sync locally or revoking consent prevents *future* uploads from that device; it does not and cannot revoke past facts already published and cached on peer devices.

### 5.2 Member Control Dimensions
1. **Global Team Sync Toggle (`teamSyncEnabled`):** Per-device, per-account setting. Default: `false`.
2. **Project Scope Association:** Projects must be explicitly designated for team sharing via project configuration or metadata (`team_id: "team_abc123"` in `.openburnbar/project.json`). Personal projects never publish to team space.
3. **Review Status Gate:** Only memories with `review_status == "approved"` can ever be mirrored or uploaded. Quarantined, pending, or rejected facts are filtered out locally before envelope sealing.
4. **Remote Config Ceiling:** The feature is guarded by Remote Config key `team_memory_sync_allowed` and `orgCeilingResolved`. If the ceiling is lowered or unresolved, team sync shuts down fail-closed.

### 5.3 Consent State Matrix

| Client State / Setting | Local Personal Memory | Personal Cloud Sync (`users/{uid}`) | Team Cloud Publish (`team_memory_facts`) | Team Cloud Pull (Ingestion) |
|---|---|---|---|---|
| **Default (Fresh Install)** | Functional (Local SQLite) | Disabled | Disabled | Disabled |
| **Personal Sync Only** | Functional | Active | Disabled | Disabled |
| **Team Sync Enabled, Project Unlinked** | Functional | Active | Disabled (Personal Project) | Active (Other Team Facts) |
| **Team Sync Enabled, Project Linked, Quarantined Fact** | Stored in quarantine | Excluded | Excluded (Quarantine Gate) | Active |
| **Team Sync Enabled, Project Linked, Approved Fact** | Stored in active set | Active | **Published to Team** | Active |
| **Member Toggles Team Sync OFF** | Functional | Active | **Halted** | **Halted** |
| **Remote Config Ceiling Closed** | Functional | Active | **Halted** | **Halted** |

---

## 6. Leave-Team Rotation Semantics: Forward Secrecy and Key Escrow

### 6.1 Team Key Distribution Hierarchy
Team keys are distributed using asymmetric P-256 / ECIES key escrow, mirroring the existing `CloudVaultCrypto` pattern without BurnBar servers ever seeing the key:
1. When a user joins, their device publishes their P-256 escrow public key to `team_rosters/{teamId}/members/{uid}.escrowPublicKey`.
2. The team administrator (or creating member) generates a random 256-bit symmetric AES key `teamVaultKey_v1`.
3. The administrator encrypts `teamVaultKey_v1` to each active member's public key, producing individual sealed envelopes.
4. Envelopes are stored in `/team_key_envelopes/{teamId}/envelopes/{memberUid}_v1`.
5. Each member downloads their personal envelope and unseals `teamVaultKey_v1` using their device private key.

### 6.2 Leave and Revocation Flow
When Member $M_{departing}$ leaves or is removed from Team $T$:

```mermaid
sequenceDiagram
    autonumber
    actor Admin as Team Admin / Owner
    participant Server as TeamRosterService (Cloud Function)
    participant Rules as Firestore Security Rules
    participant Envelopes as team_key_envelopes Collection
    actor Departed as Departing Member
    actor Remaining as Remaining Member

    Admin->>Server: removeTeamMember(teamId, targetUid)
    Server->>Server: Validate Admin Role & Stripe Seat State
    Server->>Rules: Set member status = "removed" in team_rosters
    Note over Rules: Immediate Access Cutoff<br/>Rules block Departed UID (403)
    Server->>Admin: Member removed; trigger key rotation
    Admin->>Admin: Generate teamVaultKey_v2
    Admin->>Envelopes: Publish v2 envelopes for remaining members only
    Admin->>Server: rotateTeamKey(teamId, v2)
    Server->>Rules: Update team_rosters.activeKeyVersion = 2
    Remaining->>Envelopes: Fetch & unwrap v2 envelope
    Departed--xRules: Attempt read/write -> BLOCKED by rules
```

1. **Step 1: Roster Status Invalidation:** `TeamRosterService` sets `status = "removed"` in `team_rosters/{teamId}/members/{departedUid}`.
2. **Step 2: Immediate Rules Cutoff:** Firestore security rules evaluate the live roster status. The departing member is immediately denied all `read` and `write` access to `team_memory_facts/{teamId}/...`.
3. **Step 3: Key Generation:** An active admin client generates `teamVaultKey_v2`.
4. **Step 4: Envelope Re-wrapping:** The admin seals `teamVaultKey_v2` for every *remaining active member* and uploads the new envelopes to `/team_key_envelopes/{teamId}/envelopes/{remainingUid}_v2`. No envelope is created for the departed member.
5. **Step 5: Version Bump:** The active team key version in `team_rosters/{teamId}` is bumped to `2`.
6. **Step 6: Future Writes Enforced:** All subsequent memory writes to `/team_memory_facts/{teamId}/facts` must carry `teamKeyVersion: 2` and be encrypted under `teamVaultKey_v2`.

### 6.3 Cryptographic Boundaries and Trade-offs
- **Forward Secrecy (Protected):** The departed member cannot decrypt facts created after their departure (`teamKeyVersion >= 2`) because they never receive the `_v2` envelope.
- **Historical Retention (Cannot Hide):** The departed member already possesses `teamVaultKey_v1` and their local SQLite database containing replicated facts. Revoking server access cannot retract bits already sent over the wire.

---

## 7. The Two Semantics That Must Also Appear in the UI

We cannot make cryptographic promises that mathematics and distributed systems cannot deliver. Therefore, two fundamental operational semantics must be communicated clearly and unambiguously in the user interface.

### 7.1 The Two Invariant Semantics

#### Semantic A: Join-Reads-History
> **"Joining a team grants read access to all team memories sealed under the team's active keys, including memories contributed by team members before you joined."**

Because team memories are encrypted under shared team keys and stored in a shared collection, an onboarded member who receives the team key is capable of pulling and decrypting all existing historical facts for that team.

#### Semantic B: Leave-Protects-Future-Only
> **"Leaving or being removed from a team revokes your server access and rotates the team encryption key for future memories. However, it cannot erase memories or keys that have already been downloaded to your devices."**

Because BurnBar is a local-first application with offline storage, a departing member retains whatever team facts they synchronized while they were an active member. Key rotation ensures they cannot decrypt *new* memories created after their departure.

---

### 7.2 UI Copy Specifications and Locations

The following exact text strings are specified for the user interface and must be locked down by automated unit tests.

#### Location 1: Team Join / Invitation Acceptance Modal (`TeamJoinAcceptanceModal.swift`)
- **Header:** `"Join Team Memory Space"`
- **Body:**
  > `"By joining this team, your approved memories for team-linked projects will sync to the team's encrypted space.\n\n`
  > `• Historical Access: You will be able to read team memories contributed by other members before you joined.\n`
  > `• Offline Retention: Memories downloaded to devices cannot be remotely erased if you later leave the team."`
- **Confirmation Action:** `"Agree and Join Team"`

#### Location 2: Team Settings — Memory Sync Section (`TeamMemorySettingsView.swift`)
- **Section Title:** `"Team Memory Sharing"`
- **Sync Toggle Label:** `"Sync memories with team members"`
- **Explanatory Footnote:**
  > `"Team memories are protected by zero-knowledge encryption. Only active team members hold the encryption keys. Joining a team grants access to past team memories; leaving rotates encryption keys to protect future memories only."`

#### Location 3: Remove Member / Leave Team Confirmation Alert (`TeamMemberRemovalAlert.swift`)
- **Alert Title:** `"Remove Member from Team?"` (or `"Leave Team?"`)
- **Alert Message:**
  > `"Their cloud access will be revoked immediately and the team encryption key will be rotated for future memories. Note that memories and keys already downloaded to their local devices cannot be erased remotely."`
- **Destructive Action:** `"Rotate Keys and Remove"`

#### Location 4: Fact Provenance Inspector (`TeamMemoryAttributionView.swift`)
- **Badge Label:** `"Team Fact"`
- **Tooltip:** `"Shared across [Team Name] • Contributed by [Author] on [Date]"`

---

## 8. Test and Verification Matrix (Spec Acceptance)

To ensure the team memory design remains airtight and tamper-proof across all phases, the following verification gates are established:

### 8.1 Copy Gate Verification (`TeamMemoryCopyGateTests.swift`)
Following the proven pattern of `website/scripts/test-router-copy.mjs` and `website/scripts/test-trust-copy.mjs`, client unit tests will assert the exact text of Semantics A and B in UI bundles:
- `test_team_join_dialog_displays_semantic_a_historical_access_copy`
- `test_team_leave_dialog_displays_semantic_b_future_protection_only_copy`
- `test_team_settings_footnote_contains_both_invariants`

### 8.2 Firestore Security Rules Test Suite (`test_team_memory_rules.ts`)
Using the `@firebase/rules-unit-testing` framework:
- `test_non_member_is_denied_read_and_write`
- `test_member_can_read_team_facts`
- `test_member_can_write_valid_sealed_blob_with_team_aad`
- `test_member_cannot_spoof_author_uid`
- `test_member_cannot_write_plaintext_fields`
- `test_tampered_team_aad_is_rejected`
- `test_removed_member_is_denied_immediately`
- `test_client_write_to_team_roster_is_forbidden`

### 8.3 Blindness Proof Verification
BurnBar operators and servers possess only:
1. Opaque ciphertext strings (`sealedMemory.ciphertext`).
2. Opaque HMAC slugs for document IDs and source references.
3. Metadata timestamps and generic kinds (`"architecture"`, `"gotcha"`).
4. Opaque public keys and encrypted key envelopes.

At no point does plaintext fact data, embeddings, or symmetric team keys exist unencrypted in Firestore, Cloud Functions logs, or transit.
