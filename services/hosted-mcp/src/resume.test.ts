import assert from "node:assert/strict";
import test from "node:test";
import { listResumable, resumeConversation } from "./resume.js";
import type { ResumeFirestore } from "./resume.js";

const envelope = {
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  nonce: "bm9uY2U=",
  ciphertext: "Y2lwaGVydGV4dA==",
  tag: "dGFn"
};

function makeFirestore(
  extraDocuments: Array<{ id: string; data: Record<string, unknown> }> = [],
  extraPostings: Array<{ id: string; data: Record<string, unknown> }> = []
): ResumeFirestore {
  const document = {
    id: "doc-1",
    exists: true,
    data(): Record<string, unknown> {
      return {
        provider: "Goose",
        sessionId: "goose-1",
        sourceID: "Goose:goose-1",
        projectName: "FixtureApp",
        model: "gpt-5.1",
        sealedTitle: envelope,
        sealedBodyPreview: envelope,
        startTime: { toDate: () => new Date("2026-05-01T10:00:00Z") },
        endTime: { toDate: () => new Date("2026-05-01T11:00:00Z") }
      };
    },
    get(field: string) {
      const data = this.data();
      return data ? data[field] : undefined;
    }
  };
  const chunks = [
    { id: "chunk-1", data(): Record<string, unknown> { return { documentID: "doc-1", ordinal: 1, sealedSnippet: envelope }; }, get(field: string) { const data = this.data(); return data ? data[field] : undefined; } },
    { id: "chunk-0", data(): Record<string, unknown> { return { documentID: "doc-1", ordinal: 0, sealedSnippet: envelope }; }, get(field: string) { const data = this.data(); return data ? data[field] : undefined; } }
  ];
  const documents = [
    document,
    ...extraDocuments.map((item) => ({
      id: item.id,
      exists: true,
      data(): Record<string, unknown> { return item.data; },
      get(field: string) { return item.data[field]; }
    }))
  ];
  const postings = [
    {
      id: "posting-1",
      data(): Record<string, unknown> {
        return {
          postingKey: "token_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          kind: "token",
          hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          chunkID: "chunk-1",
          documentID: "doc-1",
          provider: "Goose",
          projectName: "FixtureApp"
        };
      },
      get(field: string) { const data = this.data(); return data ? data[field] : undefined; }
    },
    ...extraPostings.map((item) => ({
      id: item.id,
      data(): Record<string, unknown> { return item.data; },
      get(field: string) { return item.data[field]; }
    }))
  ];
  return {
    doc(path: string) {
      return {
        async get() {
          const found = documents.find((doc) => path.endsWith(`/cloud_search_documents/${doc.id}`));
          return found ?? { exists: false, data: () => undefined };
        }
      };
    },
    collection(path: string) {
      const docs = path.endsWith("/cloud_search_chunks")
        ? chunks
        : path.endsWith("/cloud_search_postings")
          ? postings
          : documents;
      const filters: Array<{ field: string; op: FirebaseFirestore.WhereFilterOp; value: unknown }> = [];
      const query = {
        where(field: string, _op: FirebaseFirestore.WhereFilterOp, value: unknown) {
          filters.push({ field, op: _op, value });
          return query;
        },
        orderBy() { return query; },
        limit() { return query; },
        async get() {
          return {
            docs: docs.filter((doc) => filters.every((filter) => {
              const actual = doc.get(filter.field);
              return filter.op === "in" && Array.isArray(filter.value)
                ? filter.value.includes(actual)
                : actual === filter.value;
            }))
          };
        }
      };
      return query;
    }
  };
}

test("hosted resume list returns sealed metadata only", async () => {
  const result = await listResumable(makeFirestore(), "user-1", { limit: 10 });

  assert.equal(result.items.length, 1);
  assert.equal(result.items[0].session_id, "goose-1");
  assert.equal(result.items[0].can_resume_native, false);
  assert.equal(result.items[0].summary_title_sealed, envelope);
});

test("hosted resume returns sealed response with ordered chunk hashes", async () => {
  const result = await resumeConversation(makeFirestore(), "user-1", {
    session_id: "doc-1",
    target_harness: "claude_code",
    max_tokens: 9000
  });

  assert.equal(result.kind, "ported_sealed");
  if (result.kind !== "ported_sealed") {
    throw new Error("expected ported_sealed");
  }
  assert.equal(result.header_plain.provider, "Goose");
  assert.equal(result.sealed.trail_chunks.length, 2);
  assert.equal(result.body_hashes.length, 2);
});

test("hosted resume resolves a unique opaque query hash to a sealed response", async () => {
  const result = await resumeConversation(makeFirestore(), "user-1", {
    tokenHashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    target_harness: "claude_code"
  });

  assert.equal(result.kind, "ported_sealed");
  if (result.kind !== "ported_sealed") {
    throw new Error("expected ported_sealed");
  }
  assert.equal(result.header_plain.project_name, "FixtureApp");
});

test("hosted resume refuses ambiguous opaque query hash matches", async () => {
  const result = await resumeConversation(
    makeFirestore([
      {
        id: "doc-2",
        data: {
          provider: "Codex",
          sessionId: "codex-2",
          sourceID: "Codex:codex-2",
          projectName: "FixtureApp",
          model: "gpt-5.1",
          sealedTitle: envelope,
          sealedBodyPreview: envelope
        }
      }
    ], [
      {
        id: "posting-2",
        data: {
          postingKey: "token_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          kind: "token",
          hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          chunkID: "chunk-2",
          documentID: "doc-2",
          provider: "Codex",
          projectName: "FixtureApp"
        }
      }
    ]),
    "user-1",
    { tokenHashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] }
  );

  assert.equal(result.kind, "error");
  assert.equal(result.code, "ambiguous_session");
});

test("hosted resume reports missing sessions without exposing plaintext", async () => {
  const db = makeFirestore();
  const result = await resumeConversation(db, "user-1", { session_id: "missing" });

  assert.equal(result.kind, "error");
  assert.equal(result.code, "session_not_found");
});
