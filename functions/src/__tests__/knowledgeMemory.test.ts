import { describe, expect, it } from "vitest";
import { __testing__ } from "../callables/knowledgeMemory.js";

const { PENSIEVE_LIMITS, KNOWLEDGE_VECTOR_DIM, MAX_CHUNK_BYTES, requireSourceKind, requireCloakedVector, slugify } =
  __testing__;

describe("Pensieve tier limits", () => {
  it("matches the plan's Pro and Ultra caps", () => {
    expect(PENSIEVE_LIMITS.pro).toEqual({ sources: 10, chunks: 50_000, bytes: 1 * 1024 * 1024 * 1024 });
    expect(PENSIEVE_LIMITS.ultra).toEqual({ sources: 100, chunks: 500_000, bytes: 10 * 1024 * 1024 * 1024 });
  });

  it("keeps Ultra at 10× Pro on chunks and storage (public claim)", () => {
    expect(PENSIEVE_LIMITS.ultra.chunks).toBe(PENSIEVE_LIMITS.pro.chunks * 10);
    expect(PENSIEVE_LIMITS.ultra.bytes).toBe(PENSIEVE_LIMITS.pro.bytes * 10);
  });

  it("Ultra is a strict superset of Pro on every dimension", () => {
    expect(PENSIEVE_LIMITS.ultra.sources).toBeGreaterThan(PENSIEVE_LIMITS.pro.sources);
    expect(PENSIEVE_LIMITS.ultra.chunks).toBeGreaterThan(PENSIEVE_LIMITS.pro.chunks);
    expect(PENSIEVE_LIMITS.ultra.bytes).toBeGreaterThan(PENSIEVE_LIMITS.pro.bytes);
  });
});

describe("requireSourceKind", () => {
  it("accepts the three allowed source kinds", () => {
    for (const kind of ["repo_docs", "notes", "chat_memory"]) {
      expect(requireSourceKind(kind, "sourceKind")).toBe(kind);
    }
  });
  it("rejects unknown source kinds", () => {
    expect(() => requireSourceKind("secrets", "sourceKind")).toThrow(/must be one of/);
    expect(() => requireSourceKind(undefined, "sourceKind")).toThrow();
  });
});

describe("requireCloakedVector", () => {
  it("accepts exactly KNOWLEDGE_VECTOR_DIM finite numbers", () => {
    const vec = Array.from({ length: KNOWLEDGE_VECTOR_DIM }, (_, i) => i / 1000);
    expect(requireCloakedVector(vec, "cloakedVector")).toHaveLength(KNOWLEDGE_VECTOR_DIM);
  });
  it("rejects wrong dimensions", () => {
    expect(() => requireCloakedVector([1, 2, 3], "cloakedVector")).toThrow(/384-dimension/);
    expect(() => requireCloakedVector(Array(385).fill(0), "cloakedVector")).toThrow(/384-dimension/);
  });
  it("rejects non-finite values", () => {
    const bad = Array(KNOWLEDGE_VECTOR_DIM).fill(0);
    bad[10] = Number.NaN;
    expect(() => requireCloakedVector(bad, "cloakedVector")).toThrow(/finite/);
  });
  it("rejects non-arrays", () => {
    expect(() => requireCloakedVector("nope", "cloakedVector")).toThrow();
  });
});

describe("slugify", () => {
  it("produces a safe Firestore-doc-id slug", () => {
    expect(slugify("My Repo/Docs Folder!")).toBe("my-repo-docs-folder");
    // Runs of non-alphanumerics collapse to a single dash (no doubled separators).
    expect(slugify("  trailing--dashes--  ")).toBe("trailing-dashes");
    expect(slugify("UPPER_case")).toBe("upper-case");
  });
  it("caps slug length at 120 chars", () => {
    expect(slugify("a".repeat(300)).length).toBeLessThanOrEqual(120);
  });
  it("falls back to a random id for empty input", () => {
    expect(slugify("!!!").length).toBeGreaterThan(0);
  });
});

describe("MAX_CHUNK_BYTES", () => {
  it("is a sane per-chunk ceiling", () => {
    expect(MAX_CHUNK_BYTES).toBe(64 * 1024);
  });
});
