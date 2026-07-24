import { describe, expect, it } from "vitest";

import {
  authoritativeLinuxCloudReplica,
  compareLinuxCloudReplicaOrder,
  parseLinuxCloudCursor,
  parseLinuxCloudPushRequest,
  parseLinuxCloudReplica,
} from "../callables/linuxCloudReplica.js";

type LinuxCloudRemoteReplica = ReturnType<typeof parseLinuxCloudReplica>;

function replica(overrides: Partial<LinuxCloudRemoteReplica> = {}): LinuxCloudRemoteReplica {
  return {
    domain: "usage",
    recordID: "event-1",
    revision: 1,
    modifiedAtMillis: 100,
    sourceDeviceID: "linux-a",
    tombstone: false,
    sealedPayload: {
      algorithm: "AES-256-GCM",
      keyVersion: 1,
      nonce: Buffer.alloc(12, 1).toString("base64"),
      ciphertext: Buffer.from("ciphertext").toString("base64"),
      tag: Buffer.alloc(16, 2).toString("base64"),
    },
    ...overrides,
  };
}

describe("Linux cloud replica callable contract", () => {
  it("uses revision, timestamp, then device id as a deterministic total order", () => {
    const original = replica();
    const newerRevision = replica({ revision: 2, modifiedAtMillis: 1, sourceDeviceID: "linux-0" });
    const newerTimestamp = replica({ modifiedAtMillis: 101, sourceDeviceID: "linux-0" });
    const newerDevice = replica({ sourceDeviceID: "linux-b" });

    expect(compareLinuxCloudReplicaOrder(original, newerRevision)).toBeLessThan(0);
    expect(compareLinuxCloudReplicaOrder(original, newerTimestamp)).toBeLessThan(0);
    expect(compareLinuxCloudReplicaOrder(original, newerDevice)).toBeLessThan(0);
    expect(authoritativeLinuxCloudReplica(newerRevision, original)).toEqual(newerRevision);
  });

  it("accepts the exact Swift mutation wire shape and rejects payload uid injection", () => {
    const mutation = { sequence: 7, mutationID: "linux-a:7", replica: replica() };
    expect(parseLinuxCloudPushRequest({ mutations: [mutation] })).toEqual([mutation]);
    expect(() => parseLinuxCloudPushRequest({ uid: "victim", mutations: [mutation] })).toThrow();
  });

  it("rejects malformed envelopes, mutation replay aliases, and unsafe cursors", () => {
    const validReplica = replica();
    if (validReplica.sealedPayload === null) throw new Error("fixture must include sealed payload");
    const malformedReplica = {
      ...replica(),
      sealedPayload: { ...validReplica.sealedPayload, nonce: "bad" },
    };
    expect(() => parseLinuxCloudReplica(malformedReplica)).toThrow();
    expect(() =>
      parseLinuxCloudPushRequest({
        mutations: [{ sequence: 7, mutationID: "other-device:7", replica: replica() }],
      }),
    ).toThrow();
    expect(parseLinuxCloudCursor("42")).toBe(42);
    expect(() => parseLinuxCloudCursor("0042")).toThrow();
    expect(() => parseLinuxCloudCursor("9007199254740992")).toThrow();
  });
});
