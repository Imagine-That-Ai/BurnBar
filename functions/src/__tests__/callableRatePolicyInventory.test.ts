/**
 * Callable rate-policy registry inventory.
 *
 * Every callable in the generated endpoint authorization catalog must have a
 * declared rate policy in CALLABLE_RATE_POLICIES, and every declared policy
 * must be wired honestly:
 *   - `limited` / `exempt` entries carry a real one-line justification.
 *   - `handler-enforced` entries name a bespoke limiter that the handler
 *     module actually imports and calls.
 *   - every catalog callable passes its exact exportedName to
 *     wrapCallableHandler / onCallProduction (or an audited name-factory).
 *   - no catalog callable is defined with a bare `onCall(` missing the wrapper.
 *
 * The registry is the single source of truth — this suite replaces the
 * hand-maintained CALLABLES_REQUIRING_UID_RATE_LIMIT list that lived in
 * publicEndpointRateLimitInventory.test.ts.
 */
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationCatalog } from "../security/endpointAuthorizationCatalog.generated.js";
import {
  CALLABLE_RATE_POLICIES,
  CALLABLE_RATE_TIERS,
} from "../../../packages/functions-shared/src/callables/callableRatePolicy.js";

// Tests run from functions/; module paths are repo-relative (3.5 codebases).
const REPO_DIR = resolve(process.cwd(), "..");

const callableEntries = endpointAuthorizationCatalog.filter((e) => e.trigger === "callable");
const catalogNames = new Set(callableEntries.map((e) => e.exportedName));
const registryNames = new Set(Object.keys(CALLABLE_RATE_POLICIES));

/**
 * Callables whose wrapper receives a name computed inside the definition file
 * (linuxDeviceTrustMutationCallable passes `approveLinuxAppCheckDevice` /
 * `revokeLinuxAppCheckDevice` through a `callableName` variable). For these the
 * literal is asserted to exist in the module alongside an `onCallProduction(`
 * call instead of a literal first argument.
 */
const COMPUTED_NAME_WRAPPERS = new Set(["approveLinuxAppCheckDevice", "revokeLinuxAppCheckDevice"]);

function moduleSource(module: string): string {
  const path = resolve(REPO_DIR, module);
  expect(existsSync(path), `handler module missing on disk: ${module}`).toBe(true);
  return readFileSync(path, "utf8");
}

describe("callable rate-policy registry inventory", () => {
  it("catalog callable count is nonzero", () => {
    expect(callableEntries.length).toBeGreaterThan(100);
  });

  it("every catalog callable has exactly one policy and no stale entries exist", () => {
    const missing = [...catalogNames].filter((name) => !registryNames.has(name));
    const stale = [...registryNames].filter((name) => !catalogNames.has(name));
    expect({ missing, stale }).toEqual({ missing: [], stale: [] });
  });

  it("every limited/exempt entry has a real reason and a valid tier", () => {
    const tierNames = new Set(Object.keys(CALLABLE_RATE_TIERS));
    for (const [name, policy] of Object.entries(CALLABLE_RATE_POLICIES)) {
      if (policy.kind === "handler-enforced") continue;
      expect(
        typeof policy.reason === "string" && policy.reason.trim().length >= 20,
        `${name} must carry a real one-line justification (>= 20 chars)`,
      ).toBe(true);
      if (policy.kind === "limited") {
        expect(tierNames.has(policy.tier), `${name} has an unknown tier`).toBe(true);
      }
    }
  });

  describe("handler-enforced entries import and call their checker", () => {
    for (const [name, policy] of Object.entries(CALLABLE_RATE_POLICIES)) {
      if (policy.kind !== "handler-enforced") continue;
      it(`${name} calls ${policy.checker}`, () => {
        const source = moduleSource(policy.module);
        const importPattern = new RegExp(`import[^;]*\\b${policy.checker}\\b[^;]*from`, "s");
        expect(
          importPattern.test(source),
          `${policy.module} must import ${policy.checker}`,
        ).toBe(true);
        const callPattern = new RegExp(`(?:await\\s+)?${policy.checker}\\(`);
        expect(callPattern.test(source), `${policy.module} must call ${policy.checker}`).toBe(true);
      });
    }
  });

  describe("every callable passes its exact exportedName to the wrapper", () => {
    for (const entry of callableEntries) {
      it(entry.exportedName, () => {
        const module = entry.handlerModule;
        if (!module) throw new Error(`${entry.exportedName} has no handlerModule in the catalog`);
        const source = moduleSource(module);
        // Generic argument lists may themselves contain `<...>` (e.g.
        // onCallProduction<Record<string, unknown>, R>) — match two levels of
        // nesting rather than a flat `[^>]*`.
        const literalWrapper = new RegExp(
          `(?:wrapCallableHandler|onCallProduction)\\s*(?:<(?:[^<>]|<[^<>]*>)*>)?\\s*\\(\\s*"${entry.exportedName}"`,
          "s",
        );
        if (COMPUTED_NAME_WRAPPERS.has(entry.exportedName)) {
          expect(
            /onCallProduction\(\s*callableName/s.test(source) &&
              source.includes(`"${entry.exportedName}"`),
            `${module} must route ${entry.exportedName} through onCallProduction by name`,
          ).toBe(true);
          return;
        }
        expect(
          literalWrapper.test(source),
          `${module} must wrap ${entry.exportedName} with its exact exportedName`,
        ).toBe(true);
      });
    }
  });

  it("no catalog callable is defined by a bare onCall( missing wrapCallableHandler", () => {
    // For every catalog callable whose module registers it via `onCall(`
    // directly (rather than the onCallProduction factory), the same statement
    // must pass the handler through wrapCallableHandler.
    const violations: string[] = [];
    for (const entry of callableEntries) {
      const module = entry.handlerModule;
      if (!module || !existsSync(resolve(REPO_DIR, module))) continue;
      const source = moduleSource(module);
      if (COMPUTED_NAME_WRAPPERS.has(entry.exportedName)) continue;
      const bareOnCall = new RegExp(
        `export\\s+const\\s+${entry.exportedName}\\s*=\\s*onCall\\(`,
      ).test(source);
      if (bareOnCall && !source.includes(`wrapCallableHandler(`)) {
        violations.push(entry.exportedName);
      }
    }
    expect(violations).toEqual([]);
  });

  it("every catalog handlerModule resolves to a real file", () => {
    const missing = callableEntries
      .filter((e) => !e.handlerModule || !existsSync(resolve(REPO_DIR, e.handlerModule)))
      .map((e) => `${e.exportedName} -> ${e.handlerModule}`);
    expect(missing).toEqual([]);
  });
});

// Keeps the policy union exhaustible for future kinds.
describe("registry type surface", () => {
  it("only declares the three policy kinds", () => {
    const kinds = new Set(Object.values(CALLABLE_RATE_POLICIES).map((p) => p.kind));
    expect([...kinds].sort()).toEqual(["exempt", "handler-enforced", "limited"]);
  });
});
