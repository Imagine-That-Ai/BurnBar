/**
 * Regression tests for lazy googleapis loading (perf finding crosscut-002).
 *
 * googleapis costs ~500ms at require time and all deployed functions share one
 * bundle, so an eager top-level import taxes every cold start — including
 * functions that never touch KMS/Secret Manager or Play billing. The value
 * import must stay deferred to first use (`await import("googleapis")` inside
 * the client getters); only `import type` is allowed at module scope.
 */

import { describe, expect, it, vi } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

let googleapisLoads = 0;
const destroy = vi.fn().mockResolvedValue({ data: {} });

vi.mock("googleapis", () => {
  googleapisLoads += 1;
  return {
    google: {
      auth: { getClient: vi.fn().mockResolvedValue({}) },
      cloudkms: vi.fn(() => ({})),
      secretmanager: vi.fn(() => ({ projects: { secrets: { versions: { destroy } } } })),
    },
  };
});

const SRC_DIR = resolve(__dirname, "..");

function tsFilesUnder(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "__tests__" || entry.name === "node_modules") continue;
      out.push(...tsFilesUnder(path));
    } else if (entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) {
      out.push(path);
    }
  }
  return out;
}

describe("lazy googleapis loading", () => {
  it("importing secrets.ts does not load googleapis", async () => {
    await import("../secrets.js");
    expect(googleapisLoads).toBe(0);
  });

  it("first credential operation loads googleapis on demand", async () => {
    const { destroyCredential } = await import("../secrets.js");
    await destroyCredential("projects/p/secrets/obb-test/versions/1");
    expect(googleapisLoads).toBe(1);
    expect(destroy).toHaveBeenCalledWith({ name: "projects/p/secrets/obb-test/versions/1" });
  });

  it("no module in functions/src value-imports googleapis at top level", () => {
    // Matches `import { google } from "googleapis"` (incl. multiline) and bare
    // `import "googleapis"`, while allowing `import type { ... }`.
    const eagerImport = /^import\s+(?!type\b)[^;]*?from\s+["']googleapis["']|^import\s*["']googleapis["']/m;
    const offenders = tsFilesUnder(SRC_DIR).filter((file) => eagerImport.test(readFileSync(file, "utf8")));
    expect(offenders).toEqual([]);
  });
});
