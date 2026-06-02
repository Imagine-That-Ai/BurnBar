import { describe, expect, it } from "vitest";
import { createHash } from "node:crypto";

import {
  canonicalAuditPayload,
  computeAuditHash,
  auditActorLabel,
  AUDIT_GENESIS_PREV_HASH,
  type AuditEventCore,
} from "../callables/auditLog.js";

describe("auditActorLabel — self-reported platform hint is clamped", () => {
  const withHeader = (v: unknown) =>
    auditActorLabel({ rawRequest: { headers: { "x-burnbar-platform": v } } } as never);

  it("accepts a clean platform hint", () => {
    expect(withHeader("web")).toBe("user:web");
    expect(withHeader("macos-26.1")).toBe("user:macos-26.1");
  });
  it("strips control chars / markup from a spoofed header (no audit-log injection)", () => {
    expect(withHeader("web\n<script>alert(1)</script>")).toBe("user:webscriptalert1script");
    expect(withHeader("../../etc")).toBe("user:....etc");
  });
  it("falls back to plain user when absent or fully stripped", () => {
    expect(withHeader(undefined)).toBe("user");
    expect(withHeader("！＠＃")).toBe("user");
  });
});

function makeEvent(seq: number, prevHash: string): AuditEventCore {
  return {
    seq,
    ts: `2026-06-02T00:00:0${seq}.000Z`,
    actor: "user",
    action: "data.export",
    domain: "all",
    prevHash,
  };
}

describe("canonicalAuditPayload", () => {
  it("emits keys in a fixed order regardless of input construction", () => {
    const a = canonicalAuditPayload({
      seq: 1,
      ts: "t",
      actor: "user",
      action: "x",
      domain: "d",
      prevHash: "p",
    });
    // Build a structurally-different object literal (different key insertion order).
    const reordered: AuditEventCore = { prevHash: "p", domain: "d", action: "x", actor: "user", ts: "t", seq: 1 };
    expect(canonicalAuditPayload(reordered)).toBe(a);
    expect(a).toBe('{"seq":1,"ts":"t","actor":"user","action":"x","domain":"d","prevHash":"p"}');
  });
});

describe("computeAuditHash", () => {
  it("equals sha256(prevHash + canonicalPayload)", () => {
    const core = makeEvent(0, AUDIT_GENESIS_PREV_HASH);
    const expected = createHash("sha256")
      .update(AUDIT_GENESIS_PREV_HASH + canonicalAuditPayload(core))
      .digest("hex");
    expect(computeAuditHash(core)).toBe(expected);
  });

  it("is deterministic", () => {
    const core = makeEvent(3, "abc");
    expect(computeAuditHash(core)).toBe(computeAuditHash({ ...core }));
  });

  it("changes if any field changes (tamper detection)", () => {
    const base = makeEvent(1, "prev");
    const baseHash = computeAuditHash(base);
    expect(computeAuditHash({ ...base, action: "data.delete" })).not.toBe(baseHash);
    expect(computeAuditHash({ ...base, domain: "media" })).not.toBe(baseHash);
    expect(computeAuditHash({ ...base, seq: 2 })).not.toBe(baseHash);
    expect(computeAuditHash({ ...base, prevHash: "tampered" })).not.toBe(baseHash);
  });
});

describe("hash chain integrity", () => {
  it("a valid chain re-verifies link by link", () => {
    let prevHash = AUDIT_GENESIS_PREV_HASH;
    const chain: Array<{ core: AuditEventCore; hash: string }> = [];
    for (let seq = 0; seq < 5; seq += 1) {
      const core = makeEvent(seq, prevHash);
      const hash = computeAuditHash(core);
      chain.push({ core, hash });
      prevHash = hash;
    }
    // Walk and verify.
    let expectedPrev = AUDIT_GENESIS_PREV_HASH;
    for (let i = 0; i < chain.length; i += 1) {
      const { core, hash } = chain[i];
      expect(core.seq).toBe(i);
      expect(core.prevHash).toBe(expectedPrev);
      expect(computeAuditHash(core)).toBe(hash);
      expectedPrev = hash;
    }
  });

  it("editing a middle event breaks the chain from that point on", () => {
    let prevHash = AUDIT_GENESIS_PREV_HASH;
    const chain: Array<{ core: AuditEventCore; hash: string }> = [];
    for (let seq = 0; seq < 5; seq += 1) {
      const core = makeEvent(seq, prevHash);
      const hash = computeAuditHash(core);
      chain.push({ core, hash });
      prevHash = hash;
    }
    // Tamper: change event[2]'s action but keep its stored hash.
    const tampered = { ...chain[2].core, action: "evil" };
    expect(computeAuditHash(tampered)).not.toBe(chain[2].hash);
    // event[3].prevHash still points at event[2]'s ORIGINAL hash → link mismatch
    // once event[2] is recomputed honestly.
    expect(chain[3].core.prevHash).toBe(chain[2].hash);
    expect(chain[3].core.prevHash).not.toBe(computeAuditHash(tampered));
  });
});
