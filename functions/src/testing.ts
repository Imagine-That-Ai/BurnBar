/**
 * @fileoverview Cross-codebase test seam for knip (admin codebase).
 *
 * The admin vitest suite imports sibling `src/` modules and the .mjs
 * harnesses import compiled `lib/` output. Per-package knip analyzes only
 * this package's `src/`, so it cannot see those edges; this knip entry
 * re-exports each test-consumed module as a namespace to mark it live.
 * Every entry must stay live: `scripts/ci/verify-functions-test-seams.mjs`
 * fails on a seam with no knip-invisible importer. Production code must
 * never import from this module.
 */

export * as modelLandscapeTesting from "./modelLandscape.js";
export * as rollupCountersTesting from "./rollupCounters.js";
export * as rollupsTesting from "./rollups.js";
export * as routerRundownTesting from "./routerRundown.js";
