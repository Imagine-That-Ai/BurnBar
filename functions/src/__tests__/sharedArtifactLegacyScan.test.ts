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
  constructor(private readonly docs: readonly FakeArtifactDoc[]) {}

  limit(count: number): FakeArtifactCollection {
    return new FakeArtifactCollection(this.docs.slice(0, count));
  }

  async get(): Promise<{ readonly docs: readonly FakeArtifactDoc[] }> {
    return { docs: this.docs };
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
  constructor(private readonly docs: readonly FakeTeamDoc[]) {}

  limit(count: number): FakeTeamCollection {
    return new FakeTeamCollection(this.docs.slice(0, count));
  }

  async get(): Promise<{ readonly docs: readonly FakeTeamDoc[] }> {
    return { docs: this.docs };
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
    expect(isLegacyPlaintextArtifactData({ contentSealed: true, title: "old" })).toBe(false);
    expect(isLegacyPlaintextArtifactData({ sealedPayload: { nonce: "abc" }, body: "old" })).toBe(false);
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

    const result = await scanLegacyPlaintextArtifactsForUser(db, "user-1", 10, 10, new Date("2026-06-18T00:00:00Z"));

    expect(db.requestedCollectionPaths).toEqual(["workspaces/workspace-user-1/teams"]);
    expect(result.scannedDocuments).toBe(1);
    expect(result.legacyPlaintextCount).toBe(1);
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
  });
});
