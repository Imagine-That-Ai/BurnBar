import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

const REPO_ROOT = resolve(__dirname, "../../..");
const INDEXES_PATH = resolve(REPO_ROOT, "firestore.indexes.json");

interface FirestoreIndexField {
  fieldPath: string;
  order?: "ASCENDING" | "DESCENDING";
  arrayConfig?: string;
}

interface FirestoreIndex {
  collectionGroup: string;
  queryScope: "COLLECTION" | "COLLECTION_GROUP";
  fields: FirestoreIndexField[];
}

function declaredIndexes(): FirestoreIndex[] {
  const parsed = JSON.parse(readFileSync(INDEXES_PATH, "utf8")) as { indexes?: FirestoreIndex[] };
  return parsed.indexes ?? [];
}

function hasCollectionIndex(collectionGroup: string, fields: FirestoreIndexField[]): boolean {
  return declaredIndexes().some((index) => {
    return (
      index.collectionGroup === collectionGroup &&
      index.queryScope === "COLLECTION" &&
      JSON.stringify(index.fields) === JSON.stringify(fields)
    );
  });
}

describe("Hermes Gateway event index manifest", () => {
  it("declares the collection indexes used by event polling routes", () => {
    expect(
      hasCollectionIndex("hermes_gateway_events", [
        { fieldPath: "targetClientId", order: "ASCENDING" },
        { fieldPath: "sequence", order: "ASCENDING" },
      ]),
    ).toBe(true);

    expect(
      hasCollectionIndex("hermes_gateway_events", [
        { fieldPath: "destinationId", order: "ASCENDING" },
        { fieldPath: "targetClientId", order: "ASCENDING" },
        { fieldPath: "sequence", order: "ASCENDING" },
      ]),
    ).toBe(true);

    expect(
      hasCollectionIndex("hermes_gateway_events", [
        { fieldPath: "destinationId", order: "ASCENDING" },
        { fieldPath: "sequence", order: "ASCENDING" },
      ]),
    ).toBe(true);
  });
});
