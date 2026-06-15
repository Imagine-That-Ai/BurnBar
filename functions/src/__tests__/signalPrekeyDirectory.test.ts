import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/signalPrekeyDirectory.js";

const {
  parseSignalBase64,
  assertNoForbiddenFields,
  parseFutureExpiry,
  buildSignedPreKeyDoc,
  buildOneTimePreKeyDoc,
  buildKyberPreKeyDoc,
  buildSessionDoc,
  buildRotationEventDoc,
  selectPrekeyToClaim,
  buildPrekeyClaimStamp,
  prekeyReplenishStatus,
  MIN_AVAILABLE_ONE_TIME_PREKEYS,
  MIN_AVAILABLE_KYBER_PREKEYS,
} = __testing__;

describe("prekeyReplenishStatus", () => {
  it("flags replenish when one-time or kyber prekeys run low", () => {
    expect(prekeyReplenishStatus(MIN_AVAILABLE_ONE_TIME_PREKEYS, MIN_AVAILABLE_KYBER_PREKEYS).needsReplenish).toBe(
      false,
    );
    expect(prekeyReplenishStatus(MIN_AVAILABLE_ONE_TIME_PREKEYS - 1, MIN_AVAILABLE_KYBER_PREKEYS)).toEqual({
      needsReplenish: true,
      lowOneTime: true,
      lowKyber: false,
    });
    expect(prekeyReplenishStatus(MIN_AVAILABLE_ONE_TIME_PREKEYS, MIN_AVAILABLE_KYBER_PREKEYS - 1)).toEqual({
      needsReplenish: true,
      lowOneTime: false,
      lowKyber: true,
    });
    expect(prekeyReplenishStatus(0, 0)).toEqual({ needsReplenish: true, lowOneTime: true, lowKyber: true });
  });
});

const CTX = { identityKeyId: "device-a_1", deviceId: "device-a", keyVersion: 1 };
const NOW = 1_900_000_000_000; // fixed "now" for deterministic expiry checks
const FUTURE = NOW + 60_000;
const PUB = "QUJDRA=="; // valid canonical base64
const SIG = "QUJDRUZH"; // valid canonical base64
const KYBER_PUB = "A".repeat(2000); // large but valid kyber public key

// The exact `keys().hasOnly([...])` sets from firestore.rules:3600-3882. The
// builders must never emit a key outside these; createdAt/updatedAt are added by
// the callable at write time and claimed* only on the claim update.
const RULES_KEYS = {
  signed: new Set([
    "signedPreKeyId",
    "signedPreKeyNumericId",
    "identityKeyId",
    "deviceId",
    "keyVersion",
    "publicKeyB64",
    "signatureB64",
    "algorithm",
    "status",
    "createdAt",
    "updatedAt",
    "expiresAt",
  ]),
  oneTime: new Set([
    "oneTimePreKeyId",
    "oneTimePreKeyNumericId",
    "identityKeyId",
    "deviceId",
    "keyVersion",
    "publicKeyB64",
    "algorithm",
    "status",
    "claimedBySessionId",
    "claimedAt",
    "createdAt",
    "updatedAt",
    "expiresAt",
  ]),
  kyber: new Set([
    "kyberPreKeyId",
    "kyberPreKeyNumericId",
    "identityKeyId",
    "deviceId",
    "keyVersion",
    "publicKeyB64",
    "signatureB64",
    "algorithm",
    "status",
    "claimedBySessionId",
    "claimedAt",
    "createdAt",
    "updatedAt",
    "expiresAt",
  ]),
  session: new Set([
    "sessionId",
    "identityKeyId",
    "deviceId",
    "keyVersion",
    "peerUid",
    "peerDeviceId",
    "peerIdentityKeyId",
    "mode",
    "stateStorage",
    "status",
    "createdAt",
    "updatedAt",
    "lastMessageAt",
    "archivedAt",
  ]),
  rotation: new Set([
    "rotationId",
    "identityKeyId",
    "deviceId",
    "keyVersion",
    "fromKeyVersion",
    "toKeyVersion",
    "reason",
    "status",
    "rewrapRequired",
    "rewrapJobId",
    "revokedIdentityKeyId",
    "createdAt",
    "updatedAt",
    "completedAt",
  ]),
};

function assertKeysWithin(data: Record<string, unknown>, allowed: Set<string>) {
  for (const key of Object.keys(data)) {
    expect(allowed.has(key), `unexpected key "${key}" not in rules hasOnly set`).toBe(true);
  }
}

describe("parseSignalBase64", () => {
  it("accepts canonical base64 within bounds", () => {
    expect(parseSignalBase64(PUB, "f", 256)).toBe(PUB);
    expect(parseSignalBase64(KYBER_PUB, "f", 4096)).toBe(KYBER_PUB);
  });
  it("rejects non-string, empty, bad charset, bad padding, and oversize", () => {
    expect(() => parseSignalBase64(123, "f", 256)).toThrow();
    expect(() => parseSignalBase64("", "f", 256)).toThrow();
    expect(() => parseSignalBase64("abc", "f", 256)).toThrow(); // length % 4 != 0
    expect(() => parseSignalBase64("abc$", "f", 256)).toThrow(); // bad charset
    expect(() => parseSignalBase64("AAAA", "f", 2)).toThrow(); // over maxLen
  });
});

describe("assertNoForbiddenFields", () => {
  it("rejects private-key and session-state fields (rules signalDirectoryDocumentLimits)", () => {
    for (const field of [
      "privateKeyData",
      "privateKeyB64",
      "serializedSession",
      "sessionState",
      "ratchetState",
      "apiKey",
      "secret",
    ]) {
      expect(() => assertNoForbiddenFields({ [field]: "x" }, "doc"), field).toThrow();
    }
  });
  it("is a superset of rules hasNoPlaintextSecretFields() — rejects the four names audit flagged missing", () => {
    for (const field of ["secretVersionName", "authorization", "bearer", "credential"]) {
      expect(() => assertNoForbiddenFields({ [field]: "x" }, "doc"), field).toThrow();
    }
  });
  it("accepts a payload without forbidden fields", () => {
    expect(() => assertNoForbiddenFields({ publicKeyB64: PUB }, "doc")).not.toThrow();
  });
});

describe("parseFutureExpiry", () => {
  it("requires a future, near-enough timestamp", () => {
    expect(parseFutureExpiry(FUTURE, "exp", NOW, true)?.toMillis()).toBe(FUTURE);
    expect(() => parseFutureExpiry(NOW - 1, "exp", NOW, true)).toThrow(); // past
    expect(() => parseFutureExpiry(NOW + 999 * 24 * 60 * 60 * 1000, "exp", NOW, true)).toThrow(); // too far
    expect(() => parseFutureExpiry(undefined, "exp", NOW, true)).toThrow(); // required
    expect(parseFutureExpiry(undefined, "exp", NOW, false)).toBeUndefined();
    expect(() => parseFutureExpiry("nope", "exp", NOW, true)).toThrow();
  });
});

describe("buildSignedPreKeyDoc", () => {
  it("builds a rules-shaped active signed prekey bound to the identity", () => {
    const { id, data } = buildSignedPreKeyDoc(
      { signedPreKeyId: "spk-1", signedPreKeyNumericId: 7, publicKeyB64: PUB, signatureB64: SIG },
      CTX,
      NOW,
    );
    expect(id).toBe("spk-1");
    expect(data.algorithm).toBe("signal-pqxdh-signed-prekey-v1");
    expect(data.status).toBe("active");
    expect(data.identityKeyId).toBe(CTX.identityKeyId);
    expect(data.deviceId).toBe(CTX.deviceId);
    expect(data.keyVersion).toBe(CTX.keyVersion);
    assertKeysWithin(data, RULES_KEYS.signed);
  });
  it("rejects forbidden fields and out-of-range numeric id", () => {
    expect(() =>
      buildSignedPreKeyDoc(
        { signedPreKeyId: "x", signedPreKeyNumericId: 1, publicKeyB64: PUB, signatureB64: SIG, privateKeyB64: "z" },
        CTX,
        NOW,
      ),
    ).toThrow();
    expect(() =>
      buildSignedPreKeyDoc(
        { signedPreKeyId: "x", signedPreKeyNumericId: 0, publicKeyB64: PUB, signatureB64: SIG },
        CTX,
        NOW,
      ),
    ).toThrow();
  });
});

describe("buildOneTimePreKeyDoc", () => {
  it("requires a future expiry and produces an available prekey", () => {
    const { data } = buildOneTimePreKeyDoc(
      { oneTimePreKeyId: "otp-1", oneTimePreKeyNumericId: 3, publicKeyB64: PUB, expiresAt: FUTURE },
      CTX,
      NOW,
    );
    expect(data.algorithm).toBe("signal-pqxdh-one-time-prekey-v1");
    expect(data.status).toBe("available");
    expect(data.expiresAt).toBeDefined();
    assertKeysWithin(data, RULES_KEYS.oneTime);
  });
  it("rejects a missing expiry", () => {
    expect(() =>
      buildOneTimePreKeyDoc({ oneTimePreKeyId: "otp-1", oneTimePreKeyNumericId: 3, publicKeyB64: PUB }, CTX, NOW),
    ).toThrow();
  });
});

describe("buildKyberPreKeyDoc", () => {
  it("builds an available kyber prekey with large base64 bounds", () => {
    const { data } = buildKyberPreKeyDoc(
      {
        kyberPreKeyId: "kpk-1",
        kyberPreKeyNumericId: 2,
        publicKeyB64: KYBER_PUB,
        signatureB64: SIG,
        expiresAt: FUTURE,
      },
      CTX,
      NOW,
    );
    expect(data.algorithm).toBe("signal-pqxdh-kyber-prekey-v1");
    expect(data.status).toBe("available");
    assertKeysWithin(data, RULES_KEYS.kyber);
  });
});

describe("buildSessionDoc", () => {
  it("builds device-local-only session metadata and rejects serialized state", () => {
    const { data } = buildSessionDoc(
      {
        sessionId: "sess-1",
        peerUid: "user",
        peerDeviceId: "device-b",
        peerIdentityKeyId: "device-b_1",
        mode: "same-user-device",
      },
      CTX,
      "user",
    );
    expect(data.stateStorage).toBe("device-local-only");
    expect(data.status).toBe("active");
    assertKeysWithin(data, RULES_KEYS.session);
    expect(() =>
      buildSessionDoc(
        {
          sessionId: "s",
          peerUid: "u",
          peerDeviceId: "d",
          peerIdentityKeyId: "d_1",
          mode: "same-user-device",
          serializedSession: "leak",
        },
        CTX,
        "u",
      ),
    ).toThrow();
  });
  it("rejects an unknown session mode", () => {
    expect(() =>
      buildSessionDoc(
        { sessionId: "s", peerUid: "u", peerDeviceId: "d", peerIdentityKeyId: "d_1", mode: "broadcast" },
        CTX,
        "u",
      ),
    ).toThrow();
  });
  it("rejects the not-yet-shipped cross-user gateway-transport mode (fail-closed scope)", () => {
    expect(() =>
      buildSessionDoc(
        { sessionId: "s", peerUid: "u", peerDeviceId: "d", peerIdentityKeyId: "d_1", mode: "gateway-transport" },
        CTX,
        "u",
      ),
    ).toThrow();
  });
  it("rejects a peerUid that names a DIFFERENT account (same-user multi-device scope)", () => {
    expect(() =>
      buildSessionDoc(
        {
          sessionId: "s",
          peerUid: "someone-else",
          peerDeviceId: "d",
          peerIdentityKeyId: "d_1",
          mode: "same-user-device",
        },
        CTX,
        "owner",
      ),
    ).toThrow();
  });
  it("accepts a peerUid equal to the owner (same account, another device)", () => {
    const { data } = buildSessionDoc(
      { sessionId: "s2", peerUid: "owner", peerDeviceId: "d", peerIdentityKeyId: "d_1", mode: "same-user-device" },
      CTX,
      "owner",
    );
    expect(data.peerUid).toBe("owner");
  });
});

describe("buildRotationEventDoc", () => {
  it("builds a planned, append-only rotation event with a rewrap job id when required", () => {
    const { data } = buildRotationEventDoc(
      { rotationId: "rot-1", fromKeyVersion: 1, toKeyVersion: 2, reason: "scheduled", rewrapRequired: true },
      CTX,
      "rewrap_abc123",
    );
    expect(data.status).toBe("planned");
    expect(data.rewrapRequired).toBe(true);
    expect(data.rewrapJobId).toBe("rewrap_abc123");
    assertKeysWithin(data, RULES_KEYS.rotation);
  });
  it("omits rewrapJobId when rewrap is not required and enforces version ordering", () => {
    const { data } = buildRotationEventDoc(
      { rotationId: "rot-2", fromKeyVersion: 1, toKeyVersion: 2, reason: "manual", rewrapRequired: false },
      CTX,
      "rewrap_should_be_ignored",
    );
    expect(data.rewrapJobId).toBeUndefined();
    expect(() =>
      buildRotationEventDoc(
        { rotationId: "rot-3", fromKeyVersion: 2, toKeyVersion: 2, reason: "manual", rewrapRequired: false },
        CTX,
        undefined,
      ),
    ).toThrow();
    expect(() =>
      buildRotationEventDoc(
        { rotationId: "rot-4", fromKeyVersion: 1, toKeyVersion: 2, reason: "bogus", rewrapRequired: false },
        CTX,
        undefined,
      ),
    ).toThrow();
  });
});

describe("selectPrekeyToClaim", () => {
  it("deterministically picks the lowest numericId (gap-free consumption)", () => {
    const picked = selectPrekeyToClaim([
      { id: "b", numericId: 5 },
      { id: "a", numericId: 2 },
      { id: "c", numericId: 9 },
    ]);
    expect(picked?.id).toBe("a");
  });
  it("returns undefined for an empty candidate set", () => {
    expect(selectPrekeyToClaim([])).toBeUndefined();
  });
});

// Phase 2.5 G5 — bidirectional claim invariants. The cross-device flow is:
// device B claims one of device A's published one-time prekeys to open a session;
// a one-time prekey is single-use, so a claim must CONSUME it (a second claim of
// the same id must find it gone), the claim side must reject any private/session
// state a peer might try to smuggle in, and the replenish gate must trip the
// instant availability drops below the published floors. The directory selectors
// and validators already enforce these; these tests pin the invariants so a
// regression that re-issues a consumed prekey or accepts ratchet state fails CI.
describe("G5: bidirectional cross-device claim invariants", () => {
  it("(a) selecting + the claim mutation make a one-time prekey single-use (never re-issued)", () => {
    // Both production pieces of the single-use guarantee are exercised here against the real
    // exported functions: selectPrekeyToClaim (pick the lowest-numericId available prekey) and
    // buildPrekeyClaimStamp (the mutation that flips status to "claimed"). The directory is
    // modelled exactly as the claimSignalPrekeyBundle transaction sees it — a claim queries
    // `status == "available"`, selects, then writes the claim stamp. The remaining piece, the
    // Firestore `status == "available"` query + tx.update plumbing itself, is covered by the
    // emulator integration test tracked in the Phase 2.5 handoff (out of pure-unit scope).
    type DirectoryPrekey = { id: string; numericId: number; status: string };
    const directory: DirectoryPrekey[] = [
      { id: "otp-a", numericId: 1, status: "available" },
      { id: "otp-b", numericId: 2, status: "available" },
    ];
    const available = () => directory.filter((p) => p.status === "available");
    const markClaimed = (id: string, sessionId: string) => {
      const doc = directory.find((p) => p.id === id);
      if (doc) doc.status = buildPrekeyClaimStamp(sessionId).status;
    };

    // The claim mutation IS the single-use mechanism: it marks the prekey "claimed" and
    // attributes the consuming session, removing it from future `status == "available"` queries.
    const stamp = buildPrekeyClaimStamp("session-1");
    expect(stamp.status).toBe("claimed");
    expect(stamp.claimedBySessionId).toBe("session-1");

    // First claim: lowest-numericId available prekey, then mark it claimed.
    const first = selectPrekeyToClaim(available());
    expect(first?.id).toBe("otp-a");
    if (first) markClaimed(first.id, "session-1");

    // Second claim sees only the remaining available prekey — the claimed one is excluded.
    const second = selectPrekeyToClaim(available());
    expect(second?.id).toBe("otp-b");
    if (second) markClaimed(second.id, "session-2");

    // Directory exhausted: no available prekey → claim returns undefined, never a recycled
    // (already-claimed) prekey.
    expect(selectPrekeyToClaim(available())).toBeUndefined();
    expect(directory.every((p) => p.status === "claimed")).toBe(true);
  });

  it("(b) claim side rejects every private-key and serialized-session encoding", () => {
    // A peer's claimed bundle must carry only public material. Every private /
    // ratchet / serialized-session field (including base64-suffixed variants) is
    // fail-closed, asserted via the per-iteration label so a regression names the
    // exact leaked field.
    for (const field of [
      "privateKey",
      "privateKeyData",
      "privateKeyB64",
      "serializedSession",
      "serializedSessionB64",
      "sessionState",
      "sessionStateB64",
      "ratchetState",
      "ratchetStateB64",
    ]) {
      expect(() => assertNoForbiddenFields({ [field]: "x" }, "claim"), field).toThrow();
    }
    // Presence, not truthiness: a forbidden key with an undefined value still throws.
    expect(() => assertNoForbiddenFields({ serializedSession: undefined }, "claim")).toThrow();
    // A public-only claimed bundle passes.
    expect(() =>
      assertNoForbiddenFields({ identityKeyId: "device-a_1", oneTimePreKeyId: "otp-a", publicKeyB64: PUB }, "claim"),
    ).not.toThrow();
  });

  it("(c) replenish gate trips with strict less-than at each published floor", () => {
    // At the floor: not low (strict `<`).
    expect(prekeyReplenishStatus(MIN_AVAILABLE_ONE_TIME_PREKEYS, MIN_AVAILABLE_KYBER_PREKEYS)).toEqual({
      needsReplenish: false,
      lowOneTime: false,
      lowKyber: false,
    });
    // One below the one-time floor only.
    expect(prekeyReplenishStatus(MIN_AVAILABLE_ONE_TIME_PREKEYS - 1, MIN_AVAILABLE_KYBER_PREKEYS)).toEqual({
      needsReplenish: true,
      lowOneTime: true,
      lowKyber: false,
    });
    // One below the kyber floor only.
    expect(prekeyReplenishStatus(MIN_AVAILABLE_ONE_TIME_PREKEYS, MIN_AVAILABLE_KYBER_PREKEYS - 1)).toEqual({
      needsReplenish: true,
      lowOneTime: false,
      lowKyber: true,
    });
    // Both exhausted.
    expect(prekeyReplenishStatus(0, 0)).toEqual({ needsReplenish: true, lowOneTime: true, lowKyber: true });
  });
});
