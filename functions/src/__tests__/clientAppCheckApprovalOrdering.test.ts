/**
 * Cross-platform regression guard for account-level App Check bindings.
 *
 * A Firebase Auth custom claim is shared by every signed-in app instance. When
 * the same user moves between Mac, iOS, and Android, the latest platform bind
 * replaces the previous app id. Registration and approval must therefore
 * re-bind immediately before minting their nonce and calling the high-risk
 * endpoint; relying only on the sign-in bootstrap is unsafe.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

const repoRoot = resolve(__dirname, "../../..");

const clients = [
  {
    platform: "macOS",
    path: "AgentLens/Services/ComputerUse/ComputerUseSecurityCallableClient.swift",
    registerStart: "static func registerEscrowDevice(",
    approveStart: "static func approveEscrowDeviceTrust(",
    approveEnd: "private static func buildTrustChainProof(",
  },
  {
    platform: "iOS",
    path: "OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift",
    registerStart: "static func registerEscrowDevice(",
    approveStart: "static func approveEscrowDeviceTrust(",
    approveEnd: "private static func buildTrustChainProof(",
  },
  {
    platform: "Android",
    path: "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSecurityCallableClient.kt",
    registerStart: "suspend fun registerEscrowDevice(",
    approveStart: "suspend fun approveEscrowDeviceTrust(",
    approveEnd: "suspend fun revokeEscrowDeviceTrust(",
  },
] as const;

function sourceSlice(source: string, startAnchor: string, endAnchor: string): string {
  const start = source.indexOf(startAnchor);
  expect(start, `missing ${startAnchor}`).toBeGreaterThanOrEqual(0);
  const end = source.indexOf(endAnchor, start + startAnchor.length);
  expect(end, `missing ${endAnchor}`).toBeGreaterThan(start);
  return source.slice(start, end);
}

function expectBindBeforeNonce(body: string): void {
  const bind = body.indexOf("bindAppCheckAttestation(");
  const nonce = body.indexOf("issueHighRiskActionNonce(");
  expect(bind, "high-risk client action must re-bind App Check").toBeGreaterThanOrEqual(0);
  expect(nonce, "high-risk client action must mint a nonce").toBeGreaterThanOrEqual(0);
  expect(bind, "App Check bind must happen before nonce issuance").toBeLessThan(nonce);
  // A concurrent bind from another signed-in platform can overwrite the
  // account-level claim between our bind and the nonce mint. Each client must
  // re-run the bind -> refresh -> nonce sequence when the mint is rejected at
  // the App Check binding gate.
  expect(
    body.includes("reboundHighRiskActionNonce("),
    "nonce mint must retry the bind -> refresh -> nonce sequence on a binding conflict",
  ).toBe(true);
}

describe("cross-platform App Check binding order", () => {
  for (const client of clients) {
    const source = readFileSync(resolve(repoRoot, client.path), "utf8");

    it(`${client.platform} re-binds before escrow registration`, () => {
      const body = sourceSlice(source, client.registerStart, client.approveStart);
      expectBindBeforeNonce(body);
      expect(body.indexOf("bindAppCheckAttestation(")).toBeLessThan(body.indexOf('"registerEscrowDevice"'));
    });

    it(`${client.platform} re-binds before escrow approval`, () => {
      const body = sourceSlice(source, client.approveStart, client.approveEnd);
      expectBindBeforeNonce(body);
      expect(body.indexOf("bindAppCheckAttestation(")).toBeLessThan(body.indexOf('"approveEscrowDeviceTrust"'));
    });
  }
});
