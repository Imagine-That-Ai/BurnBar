import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import {
  ROOT_COLLECTION_UID_DELETION_MANIFEST,
  ROOT_COLLECTIONS_KEYED_BY_UID,
} from "../accountDeletionRootCollections.js";

const REPO_ROOT = resolve(__dirname, "../../..");
const SRC = resolve(REPO_ROOT, "functions/src");

/** Every `.collection("X").where("uid", ...)` literal in functions/src (excluding tests). */
function discoverRootUidKeyedCollections(): Set<string> {
  const pattern = /\.collection\(\s*["']([a-z0-9_]+)["']\s*\)\s*\.where\(\s*["']uid["']/g;
  const found = new Set<string>();
  const files = readdirSync(SRC, { recursive: true, encoding: "utf8" })
    .filter((rel) => rel.endsWith(".ts") && !rel.includes("__tests__"));
  for (const rel of files) {
    const source = readFileSync(resolve(SRC, rel), "utf8");
    for (const match of source.matchAll(pattern)) {
      found.add(match[1]);
    }
  }
  return found;
}

const manifestNames = new Set(ROOT_COLLECTION_UID_DELETION_MANIFEST.map((e) => e.collection));

describe("account-deletion root-collection coverage (V-23a, GDPR Art.17)", () => {
  it("classifies every root uid-keyed collection found in the codebase", () => {
    const discovered = discoverRootUidKeyedCollections();
    expect(discovered.size).toBeGreaterThan(0); // guard against a broken scan
    const unclassified = [...discovered].filter((name) => !manifestNames.has(name)).sort();
    expect(
      unclassified,
      `Root collection(s) keyed by uid are NOT in ROOT_COLLECTION_UID_DELETION_MANIFEST and would escape ` +
        `account erasure: ${unclassified.join(", ")}. Add each to accountDeletionRootCollections.ts as ` +
        `disposition "delete" (and wire its sweep) or "exempt" (with a reason).`,
    ).toEqual([]);
  });

  it("derives the generic-sweep set from the manifest with no drift", () => {
    const expected = ROOT_COLLECTION_UID_DELETION_MANIFEST
      .filter((e) => e.disposition === "delete" && e.handledBy === "rootSweep")
      .map((e) => e.collection)
      .sort();
    expect([...ROOT_COLLECTIONS_KEYED_BY_UID].sort()).toEqual(expected);
    // Behavior parity with the pre-manifest hardcoded list.
    expect([...ROOT_COLLECTIONS_KEYED_BY_UID].sort()).toEqual(["fcm_outbound", "voip_outbound"]);
  });

  it("requires a documented reason on every manifest entry", () => {
    for (const entry of ROOT_COLLECTION_UID_DELETION_MANIFEST) {
      expect(entry.reason.trim().length, entry.collection).toBeGreaterThan(0);
      if (entry.disposition === "delete") {
        expect(entry.handledBy, `${entry.collection} delete entry must declare handledBy`).toBeTruthy();
      }
    }
  });

  it("wires every 'delete' entry to an actual sweep in accountDeletion.ts", () => {
    const deletionSource = readFileSync(resolve(SRC, "accountDeletion.ts"), "utf8");
    for (const entry of ROOT_COLLECTION_UID_DELETION_MANIFEST.filter((e) => e.disposition === "delete")) {
      if (entry.handledBy === "secretDestroy") {
        // Purged with its Secret Manager versions — referenced by name in the erase path.
        expect(deletionSource.includes(entry.collection), `${entry.collection} not referenced`).toBe(true);
      } else {
        // Generic sweep iterates ROOT_COLLECTIONS_KEYED_BY_UID; ensure it's in that set.
        expect([...ROOT_COLLECTIONS_KEYED_BY_UID]).toContain(entry.collection);
      }
    }
  });
});
