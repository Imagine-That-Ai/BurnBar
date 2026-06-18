import { describe, expect, it } from "vitest";

import {
  isLegacyPlaintextArtifactData,
  scanLegacyPlaintextArtifactsForUser,
  type LegacyScanDb,
} from "../callables/sharedArtifactLegacyScan.js";

class FakeArtifactDoc {
  readonly ref: { readonly path: string };

  constructor(
    readonly id: string,
    private readonly path: string,
    private readonly fields: Record<string, unknown>,
  ) {
    this.ref = { path };
  }

  data(): Record<string, unknown> {
    return { ...this.fields };
  }
}

class FakeArtifactCollection {
  constructor(
    private readonly docs: readonly FakeArtifactDoc[],
    private readonly cursor: { readonly mode: "after" | "at"; readonly id: string } | null = null,
    private readonly limitCount: number | null = null,
  ) {}

  orderBy(_fieldPath: unknown): FakeArtifactCollection {
    return this;
  }

  startAfter(...fieldValues: unknown[]): FakeArtifactCollection {
    return new FakeArtifactCollection(this.docs, { mode: "after", id: String(fieldValues[0]) }, this.limitCount);
  }

  startAt(...fieldValues: unknown[]): FakeArtifactCollection {
    return new FakeArtifactCollection(this.docs, { mode: "at", id: String(fieldValues[0]) }, this.limitCount);
  }

  limit(count: number): FakeArtifactCollection {
    return new FakeArtifactCollection(this.docs, this.cursor, count);
  }

  async get(): Promise<{ readonly docs: readonly FakeArtifactDoc[] }> {
    let docs = [...this.docs].sort((lhs, rhs) => lhs.id.localeCompare(rhs.id));
    const cursor = this.cursor;
    if (cursor) {
      docs = docs.filter((doc) => (cursor.mode === "after" ? doc.id > cursor.id : doc.id >= cursor.id));
    }
    if (this.limitCount != null) {
      docs = docs.slice(0, this.limitCount);
    }
    return { docs };
  }
}

class FakeTeamDoc {
  readonly ref: { collection(name: "artifacts"): FakeArtifactCollection };

  constructor(
    readonly id: string,
    artifacts: readonly FakeArtifactDoc[],
  ) {
    this.ref = {
      collection(name: "artifacts"): FakeArtifactCollection {
        expect(name).toBe("artifacts");
        return new FakeArtifactCollection(artifacts);
      },
    };
  }
}

class FakeTeamCollection {
  constructor(
    private readonly docs: readonly FakeTeamDoc[],
    private readonly cursor: { readonly mode: "after" | "at"; readonly id: string } | null = null,
    private readonly limitCount: number | null = null,
  ) {}

  orderBy(_fieldPath: unknown): FakeTeamCollection {
    return this;
  }

  startAfter(...fieldValues: unknown[]): FakeTeamCollection {
    return new FakeTeamCollection(this.docs, { mode: "after", id: String(fieldValues[0]) }, this.limitCount);
  }

  startAt(...fieldValues: unknown[]): FakeTeamCollection {
    return new FakeTeamCollection(this.docs, { mode: "at", id: String(fieldValues[0]) }, this.limitCount);
  }

  limit(count: number): FakeTeamCollection {
    return new FakeTeamCollection(this.docs, this.cursor, count);
  }

  async get(): Promise<{ readonly docs: readonly FakeTeamDoc[] }> {
    let docs = [...this.docs].sort((lhs, rhs) => lhs.id.localeCompare(rhs.id));
    const cursor = this.cursor;
    if (cursor) {
      docs = docs.filter((doc) => (cursor.mode === "after" ? doc.id > cursor.id : doc.id >= cursor.id));
    }
    if (this.limitCount != null) {
      docs = docs.slice(0, this.limitCount);
    }
    return { docs };
  }
}

class FakeLegacyScanDb implements LegacyScanDb {
  readonly requestedCollectionPaths: string[] = [];

  constructor(private readonly teams: readonly FakeTeamDoc[]) {}

  collection(path: string): FakeTeamCollection {
    this.requestedCollectionPaths.push(path);
    return new FakeTeamCollection(this.teams);
  }
}

function artifact(path: string, fields: Record<string, unknown>): FakeArtifactDoc {
  return new FakeArtifactDoc(path.split("/").at(-1) ?? path, path, fields);
}

describe("sharedArtifactLegacyScan", () => {
  it("detects unsealed plaintext fields and ignores sealed or metadata-only documents", () => {
    expect(isLegacyPlaintextArtifactData({ title: "plain" })).toBe(true);
    expect(isLegacyPlaintextArtifactData({ body: "plain" })).toBe(true);
    expect(isLegacyPlaintextArtifactData({ contentHash: "hash" })).toBe(true);
    expect(isLegacyPlaintextArtifactData({ contentSealed: true, title: "old" })).toBe(true);
    expect(isLegacyPlaintextArtifactData({ sealedPayload: { nonce: "abc" }, body: "old" })).toBe(true);
    expect(isLegacyPlaintextArtifactData({ contentSealed: true, sealedPayload: { nonce: "abc" } })).toBe(false);
    expect(isLegacyPlaintextArtifactData({ artifactID: "metadata-only" })).toBe(false);
  });

  it("scans only the caller workspace and returns paths from Firestore refs, not spoofable fields", async () => {
    const docPath = "workspaces/workspace-user-1/teams/team-real/artifacts/art-real";
    const db = new FakeLegacyScanDb([
      new FakeTeamDoc("team-real", [
        artifact(docPath, {
          artifactID: "art-declared",
          teamID: "team-spoofed",
          workspaceID: "workspace-attacker",
          revisionID: "rev-1",
          title: "secret title",
          body: "secret body",
          contentHash: "secret hash",
        }),
      ]),
    ]);

    const result = await scanLegacyPlaintextArtifactsForUser(
      db,
      "user-1",
      10,
      10,
      null,
      new Date("2026-06-18T00:00:00Z"),
    );

    expect(db.requestedCollectionPaths).toEqual(["workspaces/workspace-user-1/teams"]);
    expect(result.scannedDocuments).toBe(1);
    expect(result.legacyPlaintextCount).toBe(1);
    expect(result.nextPageToken).toBeNull();
    expect(result.scannedAt).toBe("2026-06-18T00:00:00.000Z");
    expect(result.hits).toEqual([
      {
        artifactPath: docPath,
        artifactID: "art-declared",
        workspaceID: "workspace-user-1",
        teamID: "team-real",
        revisionID: "rev-1",
        hasTitle: true,
        hasBody: true,
        hasContentHash: true,
      },
    ]);
    expect(JSON.stringify(result)).not.toContain("secret title");
    expect(JSON.stringify(result)).not.toContain("secret body");
    expect(JSON.stringify(result)).not.toContain("secret hash");
  });

  it("applies scanLimit globally across teams", async () => {
    const db = new FakeLegacyScanDb([
      new FakeTeamDoc("team-a", [
        artifact("workspaces/workspace-user-1/teams/team-a/artifacts/a1", { title: "a1" }),
        artifact("workspaces/workspace-user-1/teams/team-a/artifacts/a2", { title: "a2" }),
      ]),
      new FakeTeamDoc("team-b", [artifact("workspaces/workspace-user-1/teams/team-b/artifacts/b1", { title: "b1" })]),
    ]);

    const result = await scanLegacyPlaintextArtifactsForUser(db, "user-1", 2, 10);

    expect(result.scannedDocuments).toBe(2);
    expect(result.hits.map((hit) => hit.artifactPath)).toEqual([
      "workspaces/workspace-user-1/teams/team-a/artifacts/a1",
      "workspaces/workspace-user-1/teams/team-a/artifacts/a2",
    ]);
    expect(result.truncated).toBe(true);
    expect(result.nextPageToken).toEqual(expect.any(String));
  });

  it("applies resultLimit without scanning later teams unnecessarily", async () => {
    const db = new FakeLegacyScanDb([
      new FakeTeamDoc("team-a", [
        artifact("workspaces/workspace-user-1/teams/team-a/artifacts/a1", { title: "a1" }),
        artifact("workspaces/workspace-user-1/teams/team-a/artifacts/a2", { title: "a2" }),
      ]),
      new FakeTeamDoc("team-b", [artifact("workspaces/workspace-user-1/teams/team-b/artifacts/b1", { title: "b1" })]),
    ]);

    const result = await scanLegacyPlaintextArtifactsForUser(db, "user-1", 10, 1);

    expect(result.scannedDocuments).toBe(1);
    expect(result.hits).toHaveLength(1);
    expect(result.hits[0]?.artifactPath).toBe("workspaces/workspace-user-1/teams/team-a/artifacts/a1");
    expect(result.truncated).toBe(true);
    expect(result.nextPageToken).toEqual(expect.any(String));
  });

  it("uses nextPageToken to continue past the first scanned artifact window", async () => {
    const db = new FakeLegacyScanDb([
      new FakeTeamDoc("team-a", [
        artifact("workspaces/workspace-user-1/teams/team-a/artifacts/a1", { artifactID: "a1", title: "a1" }),
        artifact("workspaces/workspace-user-1/teams/team-a/artifacts/a2", { artifactID: "a2", title: "a2" }),
        artifact("workspaces/workspace-user-1/teams/team-a/artifacts/a3", { artifactID: "a3", title: "a3" }),
      ]),
      new FakeTeamDoc("team-b", [artifact("workspaces/workspace-user-1/teams/team-b/artifacts/b1", { title: "b1" })]),
    ]);

    const first = await scanLegacyPlaintextArtifactsForUser(db, "user-1", 2, 10);
    expect(first.truncated).toBe(true);
    expect(first.hits.map((hit) => hit.artifactID)).toEqual(["a1", "a2"]);
    expect(first.nextPageToken).toEqual(expect.any(String));

    const second = await scanLegacyPlaintextArtifactsForUser(db, "user-1", 10, 10, first.nextPageToken);
    expect(second.truncated).toBe(false);
    expect(second.nextPageToken).toBeNull();
    expect(second.hits.map((hit) => hit.artifactID)).toEqual(["a3", "b1"]);
  });
});
