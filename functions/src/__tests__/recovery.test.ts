import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/recovery.js";

const { requireSealedBlob, parseRecoveryKeyPayload, parseRecoveryContactPayload, MAX_RECOVERY_CONTACTS } = __testing__;

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
