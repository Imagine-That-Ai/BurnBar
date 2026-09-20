import Foundation
import OpenBurnBarEngine

// MARK: - Hard forget (daemon ledger)
//
// Split out of `BurnBarProjectCodeMemoryStore.swift` under
// `docs/CORE_DECOMPOSITION_PROGRAM.md`'s file-size budget when the forget path
// grew to cover the Memory Blind Sync landing zone as well. Behaviour is
// unchanged by the move: this is the same method, in the same type, under the
// same `databaseSync` transaction.
//
// What a forget must reach, and why it is more than one table: the memory's
// snapshot section (what agents read), its quarantine body, its mirrored
// syncable body (blanked, not deleted — the engine id is the only handle the
// sync lane has on the sealed cloud copy), its salience and embedding rows, and
// the OPENED plaintext another device's document left parked in
// `agent_memory_inbox`. That last one is the newest and the least obvious: no
// other delete path touches the inbox by memory, so without it a forget left a
// readable copy of the body on disk — and an unmerged copy would have been
// offered back to the engine on the next drain.
//
// A TEAM row is parked under the SEALED id the contributing member chose, not
// under the derived id the engine knows it by, so the ids below do not address
// it. `deleteSyncInboxRows` closes that half by re-deriving each parked team
// row's local id from its own provenance stamp — see its doc comment.

extension BurnBarProjectCodeMemoryStore {
    func forget(_ request: BurnBarProjectMemoryForgetRequest) throws -> BurnBarProjectMemoryForgetResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        let memoryID = request.memoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try databaseSync {
            let rows = try queryRows(
                "SELECT id, review_status FROM agent_memories WHERE id = ? AND project_id = ? LIMIT 1",
                [.text(memoryID), .text(projectID)]
            )
            let existed = rows.isEmpty == false
            // Read before the transaction blanks the mapping: this is the engine
            // id the member's other devices seal under, and it is how the parked
            // plaintext in `agent_memory_inbox` is addressed. `request.memoryID`
            // is included because the MCP engine addresses its own rows by
            // engine id, so a forget can arrive under either label.
            let engineIDs = [try engineMemoryID(projectID: projectID, memoryID: memoryID), memoryID].compactMap { $0 }
            try execute("BEGIN IMMEDIATE", [])
            do {
                // A hard forget leaves no readable copy anywhere this daemon
                // owns — including the blind-sync landing zone, whose rows are
                // opened plaintext no other delete path touches. Team rows
                // included: `deleteSyncInboxRows` re-derives their local ids
                // rather than trusting the sealed one they are parked under.
                try deleteSyncInboxRows(engineMemoryIDs: engineIDs)
                try removeProjectMemorySection(
                    projectID: projectID,
                    projectDisplayName: root.lastPathComponent,
                    memoryID: memoryID,
                    now: Self.isoNow()
                )
                try removeQuarantineMemoryBody(projectID: projectID, memoryID: memoryID)
                // A mirrored memory's body is content the member deleted, so it goes
                // now; its engine id stays so the sealed cloud copy is still
                // addressable when the forget reaches the sync lane.
                try blankAgentMemoryBody(projectID: projectID, memoryID: memoryID, now: Self.isoNow())
                // Keep a metadata tombstone so every forget remains visible to the
                // daemon-owned review/audit feed across reloads and devices. The sealed
                // body is removed above and the row is excluded from normal recall.
                try execute(
                    "UPDATE agent_memories SET body_ref = '', body_redacted = '', review_status = 'forgotten', updated_at = ? WHERE id = ? AND project_id = ?",
                    [.text(Self.isoNow()), .text(memoryID), .text(projectID)]
                )
                try execute("DELETE FROM memory_salience WHERE memory_id = ?", [.text(memoryID)])
                try execute("DELETE FROM memory_embedding_refs WHERE memory_id = ?", [.text(memoryID)])
                let auditHash = try auditEvent(
                    action: "memory.forget",
                    domain: "memory",
                    projectID: projectID,
                    subjectID: memoryID,
                    labels: ["local body delete", "metadata tombstone", "review_status:forgotten", "snapshot section removed"]
                )
                try execute("COMMIT", [])
                return BurnBarProjectMemoryForgetResponse(
                    traceID: traceID,
                    projectID: projectID,
                    memoryID: memoryID,
                    localDeleted: existed,
                    cloudDeletePending: false,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }
}
