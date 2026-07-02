import { HttpsError } from "firebase-functions/v2/https";
import { describe, expect, it } from "vitest";

import {
  booleanField,
  boundedInt,
  boundedStringArrayField,
  enumField,
  hexDigestField,
  httpsUrlField,
  optionalEnumField,
  optionalString,
  parseCallableInput,
  requiredString,
} from "../validation/callableSchema.js";

/** Capture the HttpsError a validator throws, or fail if it does not throw. */
function caughtHttpsError(action: () => unknown): HttpsError {
  try {
    action();
  } catch (error) {
    if (error instanceof HttpsError) return error;
    throw error;
  }
  throw new Error("expected an HttpsError to be thrown");
}

/** Assert a validator rejects with a structured `invalid-argument` HttpsError. */
function expectInvalidArgument(action: () => unknown, messagePattern?: RegExp): void {
  const error = caughtHttpsError(action);
  expect(error.code).toBe("invalid-argument");
  expect(error).not.toBeInstanceOf(TypeError);
  if (messagePattern) expect(error.message).toMatch(messagePattern);
}

describe("requiredString", () => {
  it("trims and returns a present value", () => {
    expect(requiredString().parse("  hello  ", "name")).toBe("hello");
  });

  it("rejects an absent or empty value as required", () => {
    expectInvalidArgument(() => requiredString().parse(undefined, "name"), /name is required/);
    expectInvalidArgument(() => requiredString().parse("   ", "name"), /name is required/);
  });

  it("enforces the max length", () => {
    expectInvalidArgument(() => requiredString({ maxLength: 3 }).parse("abcd", "name"), /3 characters or fewer/);
  });

  it("applies a format pattern with a custom message", () => {
    const field = requiredString({ pattern: /^[a-z]+$/u, patternMessage: "name must be lowercase letters." });
    expect(field.parse("abc", "name")).toBe("abc");
    expectInvalidArgument(() => field.parse("A1", "name"), /name must be lowercase letters/);
  });

  it("falls back to a generic format message when none is supplied", () => {
    expectInvalidArgument(() => requiredString({ pattern: /^[0-9]+$/u }).parse("abc", "code"), /invalid format/);
  });
});

describe("optionalString", () => {
  it("returns undefined for absent or empty input", () => {
    expect(optionalString().parse(undefined, "note")).toBeUndefined();
    expect(optionalString().parse("", "note")).toBeUndefined();
    expect(optionalString().parse("   ", "note")).toBeUndefined();
  });

  it("trims and validates a present value", () => {
    expect(optionalString({ maxLength: 8 }).parse("  hi  ", "note")).toBe("hi");
    expectInvalidArgument(() => optionalString({ maxLength: 2 }).parse("abcd", "note"), /2 characters or fewer/);
  });
});

describe("enumField", () => {
  it("accepts an allowed value and trims before matching", () => {
    expect(enumField(["sync", "all"]).parse("sync", "scope")).toBe("sync");
    expect(enumField(["sync", "all"]).parse("  all  ", "scope")).toBe("all");
  });

  it("rejects a value outside the set with the default message", () => {
    expectInvalidArgument(() => enumField(["sync", "all"]).parse("nope", "scope"), /must be one of: sync, all/);
  });

  it("supports a custom rejection message (legacy contract parity)", () => {
    const field = enumField(["sync", "all"], { maxLength: 16, message: "scope must be sync or all." });
    expectInvalidArgument(() => field.parse("nope", "scope"), /^scope must be sync or all\.$/);
  });

  it("requires a value when the field is missing", () => {
    expectInvalidArgument(() => enumField(["a", "b"]).parse(undefined, "kind"), /kind is required/);
  });
});

describe("optionalEnumField", () => {
  it("returns undefined for absent input, else validates membership", () => {
    expect(optionalEnumField(["sync", "all"]).parse(undefined, "scope")).toBeUndefined();
    expect(optionalEnumField(["sync", "all"]).parse("all", "scope")).toBe("all");
    expectInvalidArgument(
      () => optionalEnumField(["sync", "all"], { message: "scope must be sync or all." }).parse("x", "scope"),
      /scope must be sync or all/,
    );
  });
});

describe("boundedInt", () => {
  it("floors a finite number inside range", () => {
    expect(boundedInt({ min: 0, max: 10 }).parse(5.9, "count")).toBe(5);
  });

  it("rejects a non-number and an out-of-range value", () => {
    expectInvalidArgument(() => boundedInt({ min: 0, max: 10 }).parse("nope", "count"), /must be a number/);
    expectInvalidArgument(() => boundedInt({ min: 0, max: 10 }).parse(99, "count"), /between 0 and 10/);
  });
});

describe("booleanField", () => {
  it("accepts a real boolean and rejects a stringified one", () => {
    expect(booleanField().parse(true, "flag")).toBe(true);
    expectInvalidArgument(() => booleanField().parse("true", "flag"), /flag must be a boolean/);
  });
});

describe("httpsUrlField", () => {
  it("accepts an https URL and rejects plaintext http to a public host", () => {
    expect(httpsUrlField().parse("https://example.com/return", "returnUrl")).toBe("https://example.com/return");
    expectInvalidArgument(() => httpsUrlField().parse("http://example.com", "returnUrl"), /HTTPS/);
    expectInvalidArgument(() => httpsUrlField().parse("https://user:pass@example.com", "returnUrl"), /credentials/);
  });
});

describe("hexDigestField", () => {
  it("accepts a lowercase hex digest and rejects non-hex", () => {
    const digest = "a".repeat(64);
    expect(hexDigestField().parse(digest, "hash")).toBe(digest);
    expectInvalidArgument(() => hexDigestField().parse("ZZZZ", "hash"), /hex digest/);
  });
});

describe("boundedStringArrayField", () => {
  it("trims, bounds, and de-duplicates items", () => {
    expect(boundedStringArrayField({ maxLength: 10, itemMaxLength: 5 }).parse(["a", "b", "a"], "tags")).toEqual([
      "a",
      "b",
    ]);
  });

  it("rejects a non-array and an over-long list", () => {
    expectInvalidArgument(
      () => boundedStringArrayField({ maxLength: 2, itemMaxLength: 5 }).parse("x", "tags"),
      /array/,
    );
    expectInvalidArgument(
      () => boundedStringArrayField({ maxLength: 1, itemMaxLength: 5 }).parse(["a", "b"], "tags"),
      /at most 1/,
    );
  });
});

describe("parseCallableInput", () => {
  const schema = {
    purchaseToken: requiredString({ maxLength: 4096 }),
    productID: requiredString({ maxLength: 256 }),
  };

  it("returns a typed, trimmed payload", () => {
    const parsed = parseCallableInput("verifyGooglePlayCloudProTopUp", schema, {
      purchaseToken: "  tok-123 ",
      productID: "com.openburnbar.topup",
    });
    expect(parsed).toEqual({ purchaseToken: "tok-123", productID: "com.openburnbar.topup" });
  });

  it("rejects a non-object payload up front", () => {
    for (const bad of ["a string", 42, ["array"], true]) {
      expectInvalidArgument(() => parseCallableInput("c", schema, bad), /must be a JSON object/);
    }
  });

  it("treats null / undefined as an empty object so required fields still fire", () => {
    expectInvalidArgument(() => parseCallableInput("c", schema, undefined), /purchaseToken is required/);
    expectInvalidArgument(() => parseCallableInput("c", schema, null), /purchaseToken is required/);
  });

  it("preserves the field-level error contract of the underlying helpers", () => {
    expectInvalidArgument(() => parseCallableInput("c", schema, { purchaseToken: "tok" }), /productID is required/);
  });

  it("ignores unknown keys by default (backward compatible)", () => {
    const parsed = parseCallableInput("c", { scope: optionalEnumField(["sync", "all"]) }, {
      scope: "all",
      analyticsConsent: "granted",
    });
    expect(parsed).toEqual({ scope: "all" });
  });

  it("rejects unknown keys when strict mode is requested", () => {
    expectInvalidArgument(
      () =>
        parseCallableInput(
          "c",
          { scope: optionalEnumField(["sync", "all"]) },
          {
            scope: "all",
            rogue: "x",
          },
          { rejectUnknownKeys: true },
        ),
      /unexpected field "rogue"/,
    );
  });

  it("defaults an omitted optional field to undefined", () => {
    const parsed = parseCallableInput(
      "revokeAllAccess",
      { scope: optionalEnumField(["sync", "all"]) },
      {},
    );
    expect(parsed).toEqual({ scope: undefined });
  });
});
