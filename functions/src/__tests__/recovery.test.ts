import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/recovery.js";

const {
  requireSealedBlob,
  parseRecoveryKeyPayload,
  parseRecoveryContactPayload,
  MAX_RECOVERY_CONTACTS,
  requireRecoveryId,
} = __testing__;

const VALID_HASH = "a".repeat(64);

describe("requireSealedBlob", () => {
  it("accepts base64 / base64url sealed blobs", () => {
    expect(requireSealedBlob("AbC123+/=", "blob")).toBe("AbC123+/=");
    expect(requireSealedBlob("AbC-123_x=", "blob")).toBe("AbC-123_x=");
  });
  it("rejects non-base64 characters", () => {
    expect(() => requireSealedBlob("not a blob!", "blob")).toThrow(/base64/);
  });
  it("rejects empty / missing", () => {
    expect(() => requireSealedBlob("", "blob")).toThrow();
    expect(() => requireSealedBlob(undefined, "blob")).toThrow();
  });
});

describe("parseRecoveryKeyPayload", () => {
  it("accepts a well-formed recovery-key envelope", () => {
    const parsed = parseRecoveryKeyPayload({
      algorithm: "AES-256-GCM",
      wrappedVaultKey: "QUJDREVG",
      verificationHash: VALID_HASH,
      keyVersion: 2,
    });
    expect(parsed).toEqual({
      algorithm: "AES-256-GCM",
      wrappedVaultKey: "QUJDREVG",
      verificationHash: VALID_HASH,
      keyVersion: 2,
    });
  });
  it("defaults keyVersion to 1", () => {
    const parsed = parseRecoveryKeyPayload({
      algorithm: "AES-256-GCM",
      wrappedVaultKey: "QUJD",
      verificationHash: VALID_HASH,
    });
    expect(parsed.keyVersion).toBe(1);
  });
  it("rejects a non-AES algorithm", () => {
    expect(() =>
      parseRecoveryKeyPayload({ algorithm: "rot13", wrappedVaultKey: "QUJD", verificationHash: VALID_HASH }),
    ).toThrow(/AES-256-GCM/);
  });
  it("rejects a malformed verification hash", () => {
    expect(() =>
      parseRecoveryKeyPayload({ algorithm: "AES-256-GCM", wrappedVaultKey: "QUJD", verificationHash: "short" }),
    ).toThrow();
  });
  it("rejects non-object payloads", () => {
    expect(() => parseRecoveryKeyPayload("nope")).toThrow();
    expect(() => parseRecoveryKeyPayload([])).toThrow();
  });
});

describe("parseRecoveryContactPayload", () => {
  it("accepts split-knowledge contact shares with a threshold", () => {
    const parsed = parseRecoveryContactPayload({
      threshold: 2,
      contacts: [
        { contactId: "alice", sealedShare: "QQ==", contactHint: "A" },
        { contactId: "bob", sealedShare: "Qg==" },
        { contactId: "carol", sealedShare: "Qw==" },
      ],
    });
    expect(parsed.threshold).toBe(2);
    expect(parsed.contacts).toHaveLength(3);
    expect(parsed.contacts[0]).toEqual({ contactId: "alice", sealedShare: "QQ==", contactHint: "A" });
    expect(parsed.contacts[1].contactHint).toBeUndefined();
  });
  it("defaults threshold to the contact count", () => {
    const parsed = parseRecoveryContactPayload({
      contacts: [
        { contactId: "alice", sealedShare: "QQ==" },
        { contactId: "bob", sealedShare: "Qg==" },
      ],
    });
    expect(parsed.threshold).toBe(2);
  });
  it("rejects a threshold larger than the contact count", () => {
    expect(() =>
      parseRecoveryContactPayload({ threshold: 5, contacts: [{ contactId: "a", sealedShare: "QQ==" }] }),
    ).toThrow();
  });
  it("rejects an empty contact list", () => {
    expect(() => parseRecoveryContactPayload({ contacts: [] })).toThrow();
  });
  it("rejects more than the max number of contacts", () => {
    const tooMany = Array.from({ length: MAX_RECOVERY_CONTACTS + 1 }, (_, i) => ({
      contactId: `c${i}`,
      sealedShare: "QQ==",
    }));
    expect(() => parseRecoveryContactPayload({ contacts: tooMany })).toThrow();
  });
});

describe("verifyRecoveryConfirmation (delayed re-verification)", () => {
  const { verifyRecoveryConfirmation } = __testing__;
  const stored = { kind: "recovery_key", recoveryKey: { verificationHash: VALID_HASH } };

  it("accepts a matching re-entered key hash", () => {
    expect(() => verifyRecoveryConfirmation(stored, VALID_HASH)).not.toThrow();
  });
  it("rejects confirmation without a re-entered hash (no flag-flip)", () => {
    expect(() => verifyRecoveryConfirmation(stored, undefined)).toThrow(/Re-enter/);
  });
  it("rejects a wrong key hash", () => {
    expect(() => verifyRecoveryConfirmation(stored, "b".repeat(64))).toThrow(/verification failed/);
  });
  it("recovery_contact methods confirm out-of-band (no hash required)", () => {
    expect(() => verifyRecoveryConfirmation({ kind: "recovery_contact" }, undefined)).not.toThrow();
  });
});

describe("verifyRecoveryConfirmation v2 commitment (M-5 replay resistance)", () => {
  const { verifyRecoveryConfirmation, buildConfirmationCommitment, RECOVERY_CONFIRM_VERIFIER_VERSION } = __testing__;

  const commitment = buildConfirmationCommitment(VALID_HASH);
  const storedV2 = { kind: "recovery_key", recoveryKey: { ...commitment } };

  it("stores a versioned, salted one-way commitment (never the raw hash)", () => {
    expect(commitment.confirmVerifierVersion).toBe(RECOVERY_CONFIRM_VERIFIER_VERSION);
    expect(commitment.confirmSalt).toMatch(/^[0-9a-f]{32}$/);
    expect(commitment.confirmVerifier).toMatch(/^[0-9a-f]{64}$/);
    // The commitment must NOT equal the value the client sends.
    expect(commitment.confirmVerifier).not.toBe(VALID_HASH);
    expect(Object.values(commitment)).not.toContain(VALID_HASH);
  });

  it("accepts the correct re-entered verificationHash", () => {
    expect(() => verifyRecoveryConfirmation(storedV2, VALID_HASH)).not.toThrow();
  });

  it("REJECTS replay of the stored commitment value (the core M-5 fix)", () => {
    // An attacker who can read the doc has confirmVerifier; sending it must fail.
    expect(() => verifyRecoveryConfirmation(storedV2, commitment.confirmVerifier)).toThrow(/verification failed/);
  });

  it("rejects a wrong hash under the commitment scheme", () => {
    expect(() => verifyRecoveryConfirmation(storedV2, "c".repeat(64))).toThrow(/verification failed/);
  });

  it("salt is per-method (two setups of the same key yield different commitments)", () => {
    const other = buildConfirmationCommitment(VALID_HASH);
    expect(other.confirmVerifier).not.toBe(commitment.confirmVerifier);
    expect(other.confirmSalt).not.toBe(commitment.confirmSalt);
  });

  it("still requires a re-entered hash (no silent flag-flip)", () => {
    expect(() => verifyRecoveryConfirmation(storedV2, undefined)).toThrow(/Re-enter/);
  });
});

describe("requireRecoveryId", () => {
  it("accepts setup-generated recovery ids", () => {
    expect(requireRecoveryId("rec_recovery_key_abcd1234")).toBe("rec_recovery_key_abcd1234");
  });

  it("rejects path-unsafe ids", () => {
    for (const value of ["../x", "a/b", " rec_bad ", "rec_x", "rec_bad/path", "rec_bad..path"]) {
      expect(() => requireRecoveryId(value)).toThrow();
    }
  });
});
