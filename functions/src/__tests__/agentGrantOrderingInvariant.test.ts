/**
 * @fileoverview Regression guard for the queueAgentCapabilityGrantRequest
 * validation/read ORDER.
 *
 * When callables/computerUseSecurity.ts was split into sibling modules (Phase
 * 2.3 lint burn-down), the handler's checks were briefly reordered: the
 * trusted-device Firestore read (`requireTrustedEscrowDevice`, which throws
 * `permission-denied`) ended up running AFTER the clientIntentId /
 * localAuthenticationSatisfied input checks (which throw `invalid-argument`),
 * and `parseAgentGrantLocalAuthProof` ran after the delivery/timing checks.
 * That changed which HttpsError a client receives for a malformed request and
 * let an untrusted device skip the trusted-device read entirely — a security-
 * relevant behavior drift. It was caught and reverted to the original order.
 *
 * This test pins that order so it can never silently regress again. It mirrors
 * the source-wiring style already used by highRiskOwnerActionCallableGuards and
 * scripts/test-hermes-gateway.mjs: assert the relative position of load-bearing
 * steps inside the handler body. (A full behavioral test would need brittle
 * Firestore/escrow mocking to merely re-prove ordering; this is deterministic.)
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

const source = readFileSync(resolve(__dirname, "../callables/agentGrantCallables.ts"), "utf8");

/** Isolate the queueAgentCapabilityGrantRequest handler body so anchors can't
 * accidentally match identical tokens in a sibling handler. */
function handlerBody(): string {
  const start = source.indexOf("export const queueAgentCapabilityGrantRequest = onCallProduction(");
  expect(start, "queueAgentCapabilityGrantRequest handler must exist").toBeGreaterThanOrEqual(0);
  const rest = source.slice(start + 1);
  const nextExport = rest.search(/\nexport (?:const|function|async) /);
  return nextExport === -1 ? source.slice(start) : source.slice(start, start + 1 + nextExport);
}

describe("queueAgentCapabilityGrantRequest validation/read order (security invariant)", () => {
  const body = handlerBody();

  function indexOfOrFail(needle: string): number {
    const at = body.indexOf(needle);
    expect(at, `handler must contain \`${needle}\``).toBeGreaterThanOrEqual(0);
    return at;
  }

  it("parses the local-auth proof BEFORE the delivery/timing checks", () => {
    expect(indexOfOrFail("parseAgentGrantLocalAuthProof(")).toBeLessThan(indexOfOrFail("parseGrantDeliveryTiming("));
  });

  it("runs the trusted-device read BEFORE the clientIntentId input check", () => {
    expect(indexOfOrFail("requireTrustedEscrowDevice(")).toBeLessThan(
      indexOfOrFail("boundedTrimmedString(request.data.clientIntentId"),
    );
  });

  it("runs the trusted-device read BEFORE the localAuthenticationSatisfied input check", () => {
    // An untrusted device must hit permission-denied here, NOT invalid-argument.
    expect(indexOfOrFail("requireTrustedEscrowDevice(")).toBeLessThan(
      indexOfOrFail('"localAuthenticationSatisfied must be boolean."'),
    );
  });

  it("gates the local-auth proof AFTER the trusted-device read", () => {
    expect(indexOfOrFail("requireTrustedEscrowDevice(")).toBeLessThan(indexOfOrFail("enforceLocalAuthProofGate("));
  });
});
