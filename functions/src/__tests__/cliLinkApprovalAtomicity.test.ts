import { Timestamp } from "firebase-admin/firestore";
import { describe, expect, it } from "vitest";

import { finalizeCliLinkApprovalWithWrites } from "../callables/cliLinkApprovalLease.js";
import { issueRemoteMcpGrantForSignedInUser } from "../remoteMcpOAuth.js";

type StoredDocument = Record<string, unknown>;
type DocumentReference = { path: string };

function cloneStore(store: Map<string, StoredDocument>): Map<string, StoredDocument> {
  return new Map(Array.from(store, ([path, document]) => [path, { ...document }]));
}

function transactionDatabase(store: Map<string, StoredDocument>, retry = false): FirebaseFirestore.Firestore {
  return {
    doc: (path: string) => ({ path }),
    runTransaction: async (callback: (transaction: object) => Promise<unknown>) => {
      const attempts = retry ? 2 : 1;
      let result: unknown;
      for (let attempt = 0; attempt < attempts; attempt += 1) {
        const working = cloneStore(store);
        const transaction = {
          get: async (reference: DocumentReference) => {
            const document = working.get(reference.path);
            return { exists: document != null, data: () => document };
          },
          set: (reference: DocumentReference, document: StoredDocument, options?: { merge?: boolean }) => {
            working.set(reference.path, options?.merge ? { ...working.get(reference.path), ...document } : document);
          },
          update: (reference: DocumentReference, update: StoredDocument) => {
            working.set(reference.path, { ...working.get(reference.path), ...update });
          },
        };
        result = await callback(transaction);
        if (attempt + 1 < attempts) continue;
        store.clear();
        for (const [path, document] of working) store.set(path, document);
      }
      return result;
    },
  } as unknown as FirebaseFirestore.Firestore;
}

function seedClaim(store: Map<string, StoredDocument>, overrides: StoredDocument = {}): DocumentReference {
  const reference = { path: "cli_link_sessions/device-code" };
  store.set(reference.path, {
    status: "approving",
    approvalClaimUid: "alice-uid",
    approvalClaimID: "claim-id",
    expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
    ...overrides,
  });
  return reference;
}

describe("CLI link approval atomicity", () => {
  it("rolls back staged Remote MCP writes when finalization aborts", async () => {
    const store = new Map<string, StoredDocument>();
    const sessionRef = seedClaim(store);
    const db = transactionDatabase(store);

    await expect(
      finalizeCliLinkApprovalWithWrites(
        db,
        sessionRef as FirebaseFirestore.DocumentReference,
        "alice-uid",
        "claim-id",
        async (writer) => {
          await writer.doc("users/alice-uid/remote_mcp_clients/client-1").set({ clientId: "client-1" });
          throw new Error("injected before commit");
        },
      ),
    ).rejects.toThrow("injected before commit");

    expect(Array.from(store.keys())).toEqual([sessionRef.path]);
    expect(store.get(sessionRef.path)?.status).toBe("approving");
  });

  it("commits one client, grant, audit event, and envelope after a transaction retry", async () => {
    const store = new Map<string, StoredDocument>();
    const sessionRef = seedClaim(store);
    const db = transactionDatabase(store, true);
    let callbackRuns = 0;

    const issued = await finalizeCliLinkApprovalWithWrites(
      db,
      sessionRef as FirebaseFirestore.DocumentReference,
      "alice-uid",
      "claim-id",
      async (writer) => {
        callbackRuns += 1;
        const grant = await issueRemoteMcpGrantForSignedInUser(writer, "alice-uid", {
          entitlementFamily: "burnbar_pro",
          tokenSecret: "test-signing-secret",
          audience: "https://mcp.burnbar.ai/mcp",
        });
        return {
          update: { status: "approved", credentialEnvelope: { ciphertextBase64: "sealed" } },
          result: grant,
        };
      },
    );

    expect(callbackRuns).toBe(2);
    expect(Array.from(store.keys()).filter((path) => path.includes("/remote_mcp_clients/"))).toHaveLength(1);
    expect(Array.from(store.keys()).filter((path) => path.includes("/remote_mcp_grants/"))).toHaveLength(1);
    expect(Array.from(store.keys()).filter((path) => path.includes("/remote_mcp_audit_events/"))).toHaveLength(1);
    expect(store.get(sessionRef.path)).toMatchObject({
      status: "approved",
      credentialEnvelope: { ciphertextBase64: "sealed" },
    });
    expect(JSON.stringify(Array.from(store.values()))).not.toContain(issued.refreshToken);
  });

  it.each([
    ["claim mismatch", { approvalClaimID: "other-claim" }],
    ["expired claim", { expiresAt: Timestamp.fromMillis(Date.now() - 1) }],
  ])("does not stage writes for %s", async (_name, overrides) => {
    const store = new Map<string, StoredDocument>();
    const sessionRef = seedClaim(store, overrides);
    const db = transactionDatabase(store);
    let staged = false;

    await expect(
      finalizeCliLinkApprovalWithWrites(
        db,
        sessionRef as FirebaseFirestore.DocumentReference,
        "alice-uid",
        "claim-id",
        async () => {
          staged = true;
          return { update: { status: "approved" }, result: undefined };
        },
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(staged).toBe(false);
  });
});
