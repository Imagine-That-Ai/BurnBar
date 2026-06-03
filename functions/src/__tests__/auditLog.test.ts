import { describe, expect, it } from "vitest";
import { createHash } from "node:crypto";

import {
  canonicalAuditPayload,
  computeAuditHash,
  auditActorLabel,
  verifyAuditChain,
  AUDIT_GENESIS_PREV_HASH,
  type AuditEventCore,
  type AuditHead,
} from "../callables/auditLog.js";

/** Build a valid, self-consistent chain of `length` events (seq 0..length-1). */
function buildChain(length: number): Array<AuditEventCore & { hash: string }> {
  const chain: Array<AuditEventCore & { hash: string }> = [];
  let prevHash = AUDIT_GENESIS_PREV_HASH;
  for (let seq = 0; seq < length; seq += 1) {
    const core = makeEvent(seq, prevHash);
    const hash = computeAuditHash(core);
    chain.push({ ...core, hash });
    prevHash = hash;
  }
  return chain;
}

/** The head doc a server would honestly record for a chain of `length` events. */
function headFor(chain: Array<AuditEventCore & { hash: string }>, anchoredSeq?: number): AuditHead {
  const tail = chain[chain.length - 1];
  return {
    maxSeq: tail.seq,
    headHash: tail.hash,
    anchoredSeq,
    anchoredHash: anchoredSeq != null ? chain[anchoredSeq].hash : undefined,
  };
}

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

describe("verifyAuditChain — truncation detection (B-SEC-3)", () => {
  it("a full chain that reaches the recorded head is valid", () => {
    const chain = buildChain(5);
    const result = verifyAuditChain(chain, headFor(chain));
    expect(result).toEqual({ valid: true, verifiedMaxSeq: 4 });
  });

  it("an empty chain with no head is valid", () => {
    expect(verifyAuditChain([], null)).toEqual({ valid: true, verifiedMaxSeq: -1 });
  });

  it("FAILS when the tail is truncated below head.maxSeq (server suppression)", () => {
    const full = buildChain(5);
    const head = headFor(full); // head still records maxSeq=4
    const truncated = full.slice(0, 3); // server deleted seq 3 and 4
    const result = verifyAuditChain(truncated, head);
    expect(result).toEqual({ valid: false, brokenAt: 3, reason: "truncated", expectedMaxSeq: 4 });
  });

  it("FAILS when the tail is truncated below the OTS anchor even if head is rewritten", () => {
    const full = buildChain(5);
    // A colluding server deletes seq 3-4 AND rewrites the head pointer to match
    // the surviving prefix — but the head was OTS-anchored at seq 4 earlier.
    const truncated = full.slice(0, 3);
    const rewrittenHead: AuditHead = {
      maxSeq: 2,
      headHash: full[2].hash,
      anchoredSeq: 4,
      anchoredHash: full[4].hash,
    };
    const result = verifyAuditChain(truncated, rewrittenHead);
    expect(result).toEqual({ valid: false, brokenAt: 3, reason: "truncated", expectedMaxSeq: 4 });
  });

  it("still flags a broken link before applying the truncation check", () => {
    const chain = buildChain(4);
    // Corrupt the stored hash of seq 2 → link reason wins over truncation.
    chain[2] = { ...chain[2], hash: "deadbeef" };
    const result = verifyAuditChain(chain, headFor(chain));
    expect(result).toEqual({ valid: false, brokenAt: 2, reason: "link" });
  });

  it("a chain that exactly meets the anchor (no tail loss) stays valid", () => {
    const chain = buildChain(5);
    const result = verifyAuditChain(chain, headFor(chain, 4));
    expect(result).toEqual({ valid: true, verifiedMaxSeq: 4 });
  });
});
