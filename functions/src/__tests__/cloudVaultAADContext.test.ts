import { HttpsError } from "firebase-functions/v2/https";
import { describe, expect, it } from "vitest";

import { cloudVaultAADContext } from "../callables/shared.js";

function expectInvalidArgument(action: () => unknown): void {
  expect(action).toThrow(HttpsError);
  expect(action).toThrow(/invalid|required|schema/i);
  try {
    action();
  } catch (error) {
    expect(error).toMatchObject({ code: "invalid-argument" });
    expect(error).not.toBeInstanceOf(TypeError);
  }
}

describe("cloudVaultAADContext", () => {
  it("builds a stable document-bound aad context", () => {
    expect(
      cloudVaultAADContext("user_1", "cloud_search_documents", "doc-1", "sealedTitle", 2, "preview"),
    ).toBe("OpenBurnBar-CloudVault-aad-v2|user_1|cloud_search_documents|doc-1|sealedTitle|2|preview");
  });

  it("rejects malformed component shapes as structured callable errors", () => {
    const invalidValues: unknown[] = [undefined, null, 42, { value: "user_1" }, ["user_1"], Symbol("user")];

    for (const value of invalidValues) {
      expectInvalidArgument(() => cloudVaultAADContext(value, "cloud_search_documents", "doc-1", "sealedTitle"));
    }
  });

  it("rejects delimiter and control characters in aad components", () => {
    expectInvalidArgument(() => cloudVaultAADContext("user|1", "cloud_search_documents", "doc-1", "sealedTitle"));
    expectInvalidArgument(() => cloudVaultAADContext("user_1", "cloud_search_documents", "doc\n1", "sealedTitle"));
  });

  it("rejects malformed schema versions as structured callable errors", () => {
    const invalidVersions: unknown[] = [null, 1, 2.5, "2", { version: 2 }, Symbol("schema")];

    for (const version of invalidVersions) {
      expectInvalidArgument(() =>
        cloudVaultAADContext("user_1", "cloud_search_documents", "doc-1", "sealedTitle", version),
      );
    }
  });
});
