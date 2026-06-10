import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const REPO_ROOT = resolve(__dirname, "../../..");
const SRC_DIR = resolve(REPO_ROOT, "functions/src");
const GUARD = "tools/firestore-indexes/check-collection-group-coverage.mjs";

function runGuard(): { code: number; stdout: string; stderr: string } {
  try {
    const stdout = execFileSync("node", [GUARD], { cwd: REPO_ROOT, encoding: "utf8" });
    return { code: 0, stdout, stderr: "" };
  } catch (err) {
    const e: Record<string, unknown> = typeof err === "object" && err !== null ? { ...err } : {};
    return {
      code: typeof e.status === "number" ? e.status : 1,
      stdout: typeof e.stdout === "string" ? e.stdout : "",
      stderr: typeof e.stderr === "string" ? e.stderr : "",
    };
  }
}

describe("check-collection-group-coverage.mjs", () => {
  it("passes on the current tree", () => {
    const { code, stdout, stderr } = runGuard();
    expect(stderr).toBe("");
    expect(code).toBe(0);
    expect(stdout).toContain("collection-group query call sites have declared COLLECTION_GROUP index coverage");
  });

  it("fails when a collection-group query without a declared index is injected", () => {
    // Write a throwaway file querying an unindexed collection group into
    // functions/src, run the guard, and confirm it fails. The temp dir is
    // removed regardless.
    const dir = mkdtempSync(resolve(SRC_DIR, "__cg_guard_fixture_"));
    const file = resolve(dir, "injected.ts");
    try {
      writeFileSync(
        file,
        'declare const db: { collectionGroup(name: string): { where(...args: unknown[]): { get(): unknown } } };\n' +
          'export const q = db.collectionGroup("cg_guard_unindexed").where("nope", "==", true).get();\n',
        "utf8",
      );
      const { code, stderr } = runGuard();
      expect(code).toBe(1);
      expect(stderr).toContain("cg_guard_unindexed");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("declares the scheduled-job collection-group fields that broke prod (firestore.indexes.json)", () => {
    // Regression pins for the 2026-06 prod outage: reapHermesGatewayApprovals
    // and rebuildRollups threw FAILED_PRECONDITION on every cadence tick
    // because these single-field collection-group indexes were never declared.
    const declared = JSON.parse(readFileSync(resolve(REPO_ROOT, "firestore.indexes.json"), "utf8")) as {
      fieldOverrides?: Array<{
        collectionGroup: string;
        fieldPath: string;
        indexes?: Array<{ queryScope: string; order?: string }>;
      }>;
    };
    const required: Array<[string, string]> = [
      ["rollup_jobs", "dirty"],
      ["computer_use_sessions", "startedAt"],
      ["computer_use_actions", "recordedAt"],
      ["hermes_gateway_approvals", "status"],
      ["audit_meta", "maxSeq"],
      ["knowledge_sync_manifests", "lastSyncAt"],
      ["entitlements", "originalTransactionID"],
      ["entitlement_bindings", "id"],
    ];
    for (const [group, field] of required) {
      const override = declared.fieldOverrides?.find(
        (o) => o.collectionGroup === group && o.fieldPath === field,
      );
      expect(override, `${group}.${field} fieldOverride`).toBeDefined();
      const scopes = (override?.indexes ?? []).map((i) => `${i.queryScope}:${i.order}`);
      // Overrides replace the default single-field indexes, so the
      // COLLECTION-scope entries must be preserved alongside COLLECTION_GROUP.
      expect(scopes).toContain("COLLECTION_GROUP:ASCENDING");
      expect(scopes).toContain("COLLECTION:ASCENDING");
      expect(scopes).toContain("COLLECTION:DESCENDING");
    }
  });
});
