import { strict as assert } from "node:assert";
import test from "node:test";

import { loadEndpointAuthorizationCatalog } from "./sync-bola-tier2-proofs.mjs";

test("loadEndpointAuthorizationCatalog accepts generated TypeScript literal catalogs", () => {
  assert.deepEqual(
    loadEndpointAuthorizationCatalog(
      `import type { EndpointAuthorizationEntry } from "./endpointAuthorizationCatalog.js";

export const endpointAuthorizationCatalog: EndpointAuthorizationEntry[] = [
  {
    exportedName: "deleteProviderCredential",
    bolaCoverage: [
      {
        kind: "runtime-cross-user",
        covers: ["deleteProviderCredential"],
        expectedCode: "permission-denied",
        expectedOutcome: "throws",
      },
    ],
  },
] as EndpointAuthorizationEntry[];
`,
      "fixture",
    ),
    [
      {
        exportedName: "deleteProviderCredential",
        bolaCoverage: [
          {
            kind: "runtime-cross-user",
            covers: ["deleteProviderCredential"],
            expectedCode: "permission-denied",
            expectedOutcome: "throws",
          },
        ],
      },
    ],
  );
});

test("loadEndpointAuthorizationCatalog rejects executable catalog initializers", () => {
  assert.throws(
    () =>
      loadEndpointAuthorizationCatalog(
        `export const endpointAuthorizationCatalog: EndpointAuthorizationEntry[] = [
  {
    exportedName: "unsafe",
    bolaCoverage: (() => process.env.SECRET)(),
  },
] as EndpointAuthorizationEntry[];`,
        "fixture",
      ),
    /value must be a JSON-like literal/u,
  );
});

test("loadEndpointAuthorizationCatalog fails closed when the catalog export is missing", () => {
  assert.throws(() => loadEndpointAuthorizationCatalog("export const unrelated = [];", "fixture"), /Could not find/u);
});
