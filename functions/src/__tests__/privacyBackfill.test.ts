import { describe, expect, it } from "vitest";
import { FieldValue } from "firebase-admin/firestore";

import { __testing__ } from "../callables/privacyBackfill.js";

const {
  gatedDeletions,
  COLLECTION_PLANS,
  KNOWLEDGE_REPO_FIELDS,
  ROLLBACK_SNAPSHOT_FIELDS,
  PRIVACY_RESEAL_EPOCH,
  backfillUserPrivacy,
} =
  __testing__;

// FieldValue.delete() returns a fresh sentinel each call, so detect it by the
// admin SDK's structural isEqual rather than reference identity.
function isDeleteSentinel(value: unknown): boolean {
  return value instanceof FieldValue && FieldValue.delete().isEqual(value as FieldValue);
}

// ── Minimal in-memory Firestore double ──────────────────────────────────────
// Supports exactly the surface backfillUserPrivacy uses: collection().doc(),
// collection().listDocuments(), doc(path), get/update/set with FieldValue.delete.
type Doc = Record<string, unknown>;

class FakeDocRef {
  constructor(
    private readonly store: Map<string, Doc>,
    readonly path: string,
  ) {}
  async get() {
    const exists = this.store.has(this.path);
    const data = this.store.get(this.path);
    return {
      exists,
      data: () => (data ? { ...data } : undefined),
      get: (field: string) => (data ? data[field] : undefined),
    };
  }
  async update(patch: Record<string, unknown>) {
    const current = this.store.get(this.path);
    if (!current) throw new Error(`update on missing doc ${this.path}`);
    const next = { ...current };
    for (const [key, value] of Object.entries(patch)) {
      if (isDeleteSentinel(value)) delete next[key];
      else next[key] = value;
    }
    this.store.set(this.path, next);
  }
  async set(patch: Record<string, unknown>, opts?: { merge?: boolean }) {
    const current = opts?.merge ? (this.store.get(this.path) ?? {}) : {};
    this.store.set(this.path, { ...current, ...patch });
  }
  collection(name: string) {
    return new FakeCollectionRef(this.store, `${this.path}/${name}`);
  }
}

class FakeCollectionRef {
  constructor(
    private readonly store: Map<string, Doc>,
    readonly path: string,
  ) {}
  doc(id: string) {
    return new FakeDocRef(this.store, `${this.path}/${id}`);
  }
  async listDocuments() {
    const prefix = `${this.path}/`;
    const ids = new Set<string>();
    for (const key of this.store.keys()) {
      if (!key.startsWith(prefix)) continue;
      const rest = key.slice(prefix.length);
      if (rest.includes("/")) continue; // only direct children
      ids.add(rest);
    }
    return [...ids].map((id) => new FakeDocRef(this.store, `${prefix}${id}`));
  }
}

class FakeFirestore {
  readonly store = new Map<string, Doc>();
  collection(name: string) {
    return new FakeCollectionRef(this.store, name);
  }
  doc(path: string) {
    return new FakeDocRef(this.store, path);
  }
  seed(path: string, data: Doc) {
    this.store.set(path, data);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  asFirestore() {
    return this as unknown as any;
  }
}

describe("gatedDeletions — safe-by-construction", () => {
  it("deletes a plaintext field ONLY when its sealed gate is present", () => {
    const fields = [{ field: "projectName", requires: "sealedProjectName" }];
    expect(gatedDeletions({ projectName: "secret-proj", sealedProjectName: {} }, fields)).toEqual([
      "projectName",
    ]);
  });

  it("never deletes a plaintext field while its sealed copy is absent", () => {
    const fields = [{ field: "projectName", requires: "sealedProjectName" }];
    expect(gatedDeletions({ projectName: "secret-proj" }, fields)).toEqual([]);
  });

  it("is a no-op when the plaintext field is already gone", () => {
    const fields = [{ field: "projectName", requires: "sealedProjectName" }];
    expect(gatedDeletions({ sealedProjectName: {} }, fields)).toEqual([]);
  });

  it("deletes unconditionally only when no gate is declared", () => {
    expect(gatedDeletions({ legacy: "x" }, [{ field: "legacy" }])).toEqual(["legacy"]);
    expect(gatedDeletions({}, [{ field: "legacy" }])).toEqual([]);
  });

  it("knowledge_repos drops cleartext repoFullName once the sealed name exists", () => {
    expect(gatedDeletions({ repoFullName: "owner/secret" }, KNOWLEDGE_REPO_FIELDS)).toEqual([]);
    expect(
      gatedDeletions({ repoFullName: "owner/secret", sealedRepoFullName: {} }, KNOWLEDGE_REPO_FIELDS),
    ).toEqual(["repoFullName"]);
  });
});

describe("COLLECTION_PLANS coverage", () => {
  it("covers the locked sealable surfaces from the contract", () => {
    const names = COLLECTION_PLANS.map((p) => p.collection);
    for (const expected of [
      "usage",
      "budgetRules",
      "mobile_assistant_chats",
      "cli_sessions",
	      "chat_threads",
	      "project_memory_snapshots",
	      "approval_policies",
	      "rollback_requests",
	      "agent_identities",
	      "subscription_topics",
	      "hermes_gateway_events",
	      "hermes_gateway_messages",
	      "hermes_gateway_attachments",
	      "media_attachment_manifests",
	    ]) {
	      expect(names).toContain(expected);
	    }
	    expect(ROLLBACK_SNAPSHOT_FIELDS.map((f) => f.field)).toEqual([
	      "actionLabel",
	      "touchedFiles",
	      "macSnapshotPath",
	    ]);
	  });

  it("every plaintext deletion has either a sealed gate or an explicit retire-only rationale", () => {
    for (const plan of COLLECTION_PLANS) {
      for (const f of plan.fields) {
        expect(
          f.requires || f.ungatedReason,
          `${plan.collection}.${f.field} must be gated or explicitly retire-only`,
        ).toBeTruthy();
      }
    }
    const ungated = COLLECTION_PLANS.flatMap((plan) =>
      plan.fields
        .filter((field) => !field.requires)
        .map((field) => ({
          collection: plan.collection,
          field: field.field,
          reason: field.ungatedReason,
        })),
    );
    expect(ungated).toEqual([
      {
        collection: "budgetEvents",
        field: "detailJSON",
        reason: "retired local-only diagnostic detail; current cloud writers omit it and rules reject it",
      },
    ]);
  });
});

describe("backfillUserPrivacy — idempotent end-to-end", () => {
  it("strips gated plaintext, preserves ungated, and bumps the reseal watermark", async () => {
    const fake = new FakeFirestore();
    // Sealed copy present → plaintext is dropped.
    fake.seed("users/u1/usage/a", { projectName: "alpha", sealedProjectName: { ciphertext: "x" }, tokens: 10 });
    // No sealed copy yet → plaintext is preserved (still renders).
    fake.seed("users/u1/usage/b", { projectName: "beta", tokens: 5 });
    // Project memory with sealed snapshot → identity duplicates dropped.
    fake.seed("users/u1/project_memory_snapshots/pm_abc", {
      projectDisplayName: "MySecretApp",
      projectSlug: "my-secret-app",
      sealedSnapshot: { sealedBoxBase64: "z" },
      schemaVersion: 2,
    });
    // knowledge_repos with sealed name → cleartext repo name dropped.
	    fake.seed("users/u1/knowledge_repos/r1", {
	      repoFullName: "owner/private",
	      repoMatchToken: "abc123",
	      sealedRepoFullName: { ciphertext: "y" },
	    });
	    fake.seed("users/u1/approval_policies/ap_abc", {
	      id: "decision=approve|glob=src/**|project=Secret",
	      displayLabel: "Always approve Secret",
	      fileGlob: "src/**",
	      targetProject: "Secret",
	      sealedDisplayLabel: { ciphertext: "label" },
	      sealedFileGlob: { ciphertext: "glob" },
	      sealedTargetProject: { ciphertext: "project" },
	      decision: "approve",
	    });
	    fake.seed("users/u1/rollback_requests/req1", {
	      scopeJSON: "{\"kind\":\"singleFile\",\"path\":\"/Users/me/secret.swift\"}",
	      errorMessage: "failed at /Users/me",
	      sealedScope: { ciphertext: "scope" },
	      sealedErrorMessage: { ciphertext: "error" },
	      status: "failed",
	    });
	    fake.seed("users/u1/agent_identities/a1", {
	      displayName: "Research Scout",
	      tagline: "Reads private projects",
	      personas: [{ id: "p1", name: "Default" }],
	      sealedDisplayName: { ciphertext: "name" },
	      sealedTagline: { ciphertext: "tagline" },
	      sealedPersonas: { ciphertext: "personas" },
	    });
		    fake.seed("users/u1/subscription_topics/t1", {
		      agentURI: "agent://research",
		      topicID: "agent-updates",
		      displayName: "Research Scout updates",
		      description: "Private digest",
		      sealedAgentURI: { ciphertext: "topic-agent" },
		      sealedTopicID: { ciphertext: "topic-id" },
		      sealedDisplayName: { ciphertext: "topic-name" },
		      sealedDescription: { ciphertext: "topic-desc" },
		    });
		    fake.seed("users/u1/hermes_gateway_events/e1", {
		      text: "private prompt",
		      senderDisplayName: "Alberto",
		      threadId: "thread-secret",
		      relayEnvelope: { payloadCiphertext: "x", wrappedKey: "y" },
		      kind: "message",
		    });
		    fake.seed("users/u1/hermes_gateway_messages/m1", {
		      text: "private reply",
		      relayEnvelope: { payloadCiphertext: "x", wrappedKey: "y" },
		      kind: "agent_message",
		    });
		    fake.seed("users/u1/hermes_gateway_attachments/a1", {
		      fileName: "Secret.pdf",
		      relayEnvelope: { payloadCiphertext: "x", wrappedKey: "y" },
		      storagePath: "users/u1/hermes_gateway_attachments/c1/a1",
		    });
		    fake.seed("users/u1/media_attachment_manifests/mm1", {
		      filename: "Private.png",
		      sealedFilename: { ciphertext: "media-name" },
		      storagePath: "users/u1/media/mm1",
		    });
		    fake.seed("users/u1/cli_sessions/s1", { sealedPayload: { ciphertext: "session" } });
	    fake.seed("users/u1/cli_sessions/s1/snapshots/snap1", {
	      actionLabel: "Edit src/secret.swift",
	      touchedFiles: ["src/secret.swift"],
	      macSnapshotPath: "/Users/me/.burnbar/snap1",
	      sealedActionLabel: { ciphertext: "action" },
	      sealedTouchedFiles: { ciphertext: "files" },
	      sealedMacSnapshotPath: { ciphertext: "path" },
	    });

    const stats = await backfillUserPrivacy(fake.asFirestore(), "u1");

		    expect(stats.deletedFields).toBe(26);
	    expect(stats.resealBumped).toBe(true);

    // Sealed-backed doc: plaintext gone, sealed + metadata intact.
    expect(fake.store.get("users/u1/usage/a")).toEqual({
      sealedProjectName: { ciphertext: "x" },
      tokens: 10,
    });
    // Unsealed doc: plaintext preserved (no data loss in the migration window).
    expect(fake.store.get("users/u1/usage/b")).toEqual({ projectName: "beta", tokens: 5 });
    // Project memory: identity duplicates gone, sealed body + schema intact.
    expect(fake.store.get("users/u1/project_memory_snapshots/pm_abc")).toEqual({
      sealedSnapshot: { sealedBoxBase64: "z" },
      schemaVersion: 2,
    });
    // knowledge_repos: cleartext name gone, opaque token + sealed name intact.
	    expect(fake.store.get("users/u1/knowledge_repos/r1")).toEqual({
	      repoMatchToken: "abc123",
	      sealedRepoFullName: { ciphertext: "y" },
	    });
	    expect(fake.store.get("users/u1/approval_policies/ap_abc")).toEqual({
	      sealedDisplayLabel: { ciphertext: "label" },
	      sealedFileGlob: { ciphertext: "glob" },
	      sealedTargetProject: { ciphertext: "project" },
	      decision: "approve",
	    });
	    expect(fake.store.get("users/u1/rollback_requests/req1")).toEqual({
	      sealedScope: { ciphertext: "scope" },
	      sealedErrorMessage: { ciphertext: "error" },
	      status: "failed",
	    });
	    expect(fake.store.get("users/u1/agent_identities/a1")).toEqual({
	      sealedDisplayName: { ciphertext: "name" },
	      sealedTagline: { ciphertext: "tagline" },
	      sealedPersonas: { ciphertext: "personas" },
	    });
		    expect(fake.store.get("users/u1/subscription_topics/t1")).toEqual({
		      sealedAgentURI: { ciphertext: "topic-agent" },
		      sealedTopicID: { ciphertext: "topic-id" },
		      sealedDisplayName: { ciphertext: "topic-name" },
		      sealedDescription: { ciphertext: "topic-desc" },
		    });
		    expect(fake.store.get("users/u1/hermes_gateway_events/e1")).toEqual({
		      relayEnvelope: { payloadCiphertext: "x", wrappedKey: "y" },
		      kind: "message",
		    });
		    expect(fake.store.get("users/u1/hermes_gateway_messages/m1")).toEqual({
		      relayEnvelope: { payloadCiphertext: "x", wrappedKey: "y" },
		      kind: "agent_message",
		    });
		    expect(fake.store.get("users/u1/hermes_gateway_attachments/a1")).toEqual({
		      relayEnvelope: { payloadCiphertext: "x", wrappedKey: "y" },
		      storagePath: "users/u1/hermes_gateway_attachments/c1/a1",
		    });
		    expect(fake.store.get("users/u1/media_attachment_manifests/mm1")).toEqual({
		      sealedFilename: { ciphertext: "media-name" },
		      storagePath: "users/u1/media/mm1",
		    });
	    expect(fake.store.get("users/u1/cli_sessions/s1/snapshots/snap1")).toEqual({
	      sealedActionLabel: { ciphertext: "action" },
	      sealedTouchedFiles: { ciphertext: "files" },
	      sealedMacSnapshotPath: { ciphertext: "path" },
	    });
    // Watermark written at the current epoch.
    expect(fake.store.get("users/u1/privacy_reseal_state/current")?.resealEpoch).toBe(PRIVACY_RESEAL_EPOCH);

    // Idempotency: a second run deletes nothing and does not re-bump.
    const again = await backfillUserPrivacy(fake.asFirestore(), "u1");
    expect(again.deletedFields).toBe(0);
    expect(again.updatedDocs).toBe(0);
    expect(again.resealBumped).toBe(false);
  });
});
