import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { EVENT } from "../src/lib/analytics/events";

/**
 * Governance: the canonical taxonomy (docs/analytics/event-taxonomy.md) is the single source of
 * truth. Every website event name MUST be registered there — an off-taxonomy name fails CI. This is
 * the enforcement the taxonomy's § Governance promises ("Add the event here first").
 */
const HERE = dirname(fileURLToPath(import.meta.url));
const TAXONOMY = join(HERE, "..", "..", "docs", "analytics", "event-taxonomy.md");

/** Event names are backtick-wrapped `surface.object.action` tokens (≥1 dot, lowercase/underscore
 *  segments). Property/enum tokens are dot-free, so they don't match. */
function registeredEventNames(): Set<string> {
  const doc = readFileSync(TAXONOMY, "utf8");
  const names = new Set<string>();
  for (const m of doc.matchAll(/`([a-z0-9]+(?:\.[a-z0-9_]+)+)`/g)) {
    const tok = m[1];
    // exclude domains / dotted non-events (e.g. api2.amplitude.com, trackingOptions.ipAddress)
    if (/\.(com|ai|net|org|io)$/.test(tok)) continue;
    if (/[A-Z]/.test(m[1])) continue;
    names.add(tok);
  }
  return names;
}

describe("website events are all registered in the canonical taxonomy", () => {
  const registered = registeredEventNames();

  it("the taxonomy doc parses to a non-trivial set of event names", () => {
    expect(registered.size).toBeGreaterThan(20);
    expect(registered.has("screen.viewed")).toBe(true);
    expect(registered.has("consent.analytics.granted")).toBe(true);
  });

  it("every EVENT wire name exists in event-taxonomy.md", () => {
    const missing = Object.values(EVENT).filter((name) => !registered.has(name));
    expect(missing, `off-taxonomy event names: ${missing.join(", ")}`).toEqual([]);
  });
});
