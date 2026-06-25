import { createHash } from "node:crypto";

import { describe, expect, it } from "vitest";

import { deviceLinkLogFields } from "../domains/device-links/store.js";

const LOG_HASH_VERSION = "openburnbar:device-link-log:v1";

function expectedHash(kind: "user" | "account" | "device", value: string): string {
  return createHash("sha256")
    .update(LOG_HASH_VERSION)
    .update("\0")
    .update(kind)
    .update("\0")
    .update(value.trim())
    .digest("hex")
    .slice(0, 16);
}

describe("device link log privacy", () => {
  it("emits deterministic correlation hashes without raw stable identifiers", () => {
    const uid = "AbCdEf0123456789AbCdEf012345";
    const accountID = "stripe-owner-alberto@example.test";
    const deviceID = "Example-MacBook-Pro-Serial-ABC123";

    const fields = deviceLinkLogFields(uid, accountID, deviceID);

    expect(fields).toEqual({
      user_id_hash: expectedHash("user", uid),
      account_id_hash: expectedHash("account", accountID),
      device_id_hash: expectedHash("device", deviceID),
    });
    expect(fields).not.toHaveProperty("account_id");
    expect(fields).not.toHaveProperty("device_id");

    const serialized = JSON.stringify(fields);
    expect(serialized).not.toContain(uid);
    expect(serialized).not.toContain(uid.slice(0, 8));
    expect(serialized).not.toContain(accountID);
    expect(serialized).not.toContain(deviceID);
  });

  it("separates account and device hash namespaces for identical values", () => {
    const sharedValue = "shared-stable-id";

    const fields = deviceLinkLogFields("user-1", sharedValue, sharedValue);

    expect(fields.account_id_hash).toBe(expectedHash("account", sharedValue));
    expect(fields.device_id_hash).toBe(expectedHash("device", sharedValue));
    expect(fields.account_id_hash).not.toBe(fields.device_id_hash);
  });
});
