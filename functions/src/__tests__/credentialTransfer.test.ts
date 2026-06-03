import { describe, expect, it } from "vitest";

import { __testing__ } from "../callables/credentialTransfer.js";

const { normalizeCredentialTransferCode } = __testing__;

describe("normalizeCredentialTransferCode", () => {
  it("normalizes user-entered separators and case", () => {
    expect(normalizeCredentialTransferCode(" abcd-efgh jkm2 ")).toBe("ABCDEFGHJKM2");
  });

  it("rejects path-unsafe or malformed transfer codes", () => {
    for (const value of ["../ABCDEFGHJKM2", "ABCDEFGHJKM/", "ABCDEFGHJKM", "ABCDEFGHIJKL", "AAAAAAAAAAAAA"]) {
      expect(() => normalizeCredentialTransferCode(value)).toThrow();
    }
  });
});
