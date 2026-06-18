import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { EVENT } from "../lib/analytics/events";

/**
 * Governance: every wire name in the console event registry MUST be registered
 * in the canonical taxonomy. The taxonomy is the single source of truth — an
 * instrumentation call may never reference a name that isn't documented there.
 *
 * Registered events appear in the doc as inline-code `surface.object.action`
 * tokens inside the tables. We extract that set with a regex over backtick-
 * wrapped tokens containing a dot, then assert the registry is a subset. An
 * off-taxonomy name (renamed/dropped/typo'd) fails this test.
 */
const HERE = dirname(fileURLToPath(import.meta.url));
const TAXONOMY_PATH = resolve(HERE, "..", "..", "..", "docs", "analytics", "event-taxonomy.md");

/** Backtick-wrapped dotted tokens: e.g. `passkey.enrollment.completed`. */
const WIRE_TOKEN_RE = /`([a-z0-9]+(\.[a-z0-9_]+)+)`/g;

function registeredWireNames(): Set<string> {
  const doc = readFileSync(TAXONOMY_PATH, "utf8");
  const names = new Set<string>();
  for (const match of doc.matchAll(WIRE_TOKEN_RE)) {
    names.add(match[1]);
  }
  return names;
}

describe("event taxonomy governance", () => {
  it("reads a non-empty taxonomy with the documented event tokens", () => {
    const registered = registeredWireNames();
    // The doc registers dozens of events across every platform; if extraction
    // ever silently returns nothing (moved file, format change), fail loudly
    // instead of letting an empty set vacuously pass the subset assertion.
    expect(registered.size).toBeGreaterThan(20);
    // Anchor on a known console + a known Tier 1 token so a regex regression
    // that drops dotted matches is caught here, not by a false green below.
    expect(registered.has("passkey.enrollment.completed")).toBe(true);
    expect(registered.has("auth.sign_in.completed")).toBe(true);
  });

  it("every console registry wire name is registered in the taxonomy", () => {
    const registered = registeredWireNames();
    const offTaxonomy = Object.values(EVENT).filter((name) => !registered.has(name));
    // Empty array on success; on failure the message names the exact offenders.
    expect(offTaxonomy, `off-taxonomy console event names: ${offTaxonomy.join(", ")}`).toEqual([]);
  });

  it("rejects an off-taxonomy name (negative control)", () => {
    const registered = registeredWireNames();
    // A name we deliberately never register must NOT be a member — proves the
    // assertion above can actually fail rather than always passing.
    expect(registered.has("passkey.enrollment.bogus_action")).toBe(false);
  });
});
