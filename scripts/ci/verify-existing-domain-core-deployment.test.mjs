import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { verifyExistingDeployment } from "./verify-existing-domain-core-deployment.mjs";

const artifactBytes = Buffer.from("manifest\n");
const digest = createHash("sha256").update(artifactBytes).digest("hex");
const commit = "a".repeat(40);
const tag = "v1.2.3";

function receipt(consumer) {
  return {
    schemaVersion: 2,
    consumer,
    candidate: { candidateCommit: commit },
    release: { tag, commit },
    deployment: {
      status: "healthy",
      deployedArtifact: { sha256: digest },
      providerCoordinates:
        consumer === "console"
          ? {
              sites: [
                {
                  target: "marketing",
                  site: "burnbar",
                  versionName: "sites/burnbar/versions/1",
                  releaseName: "sites/burnbar/channels/live/releases/1",
                },
                {
                  target: "console",
                  site: "burnbar-console",
                  versionName: "sites/burnbar-console/versions/2",
                  releaseName: "sites/burnbar-console/channels/live/releases/2",
                },
              ],
            }
          : {
              buildArtifactSha256: digest,
              sharedSource: {
                bucket: "sources",
                object: "source.zip",
                generation: "42",
              },
              targets: [
                {
                  target: "healthLive",
                  service: "projects/x/services/healthlive",
                  revision: "healthlive-1",
                },
                {
                  target: "healthReady",
                  service: "projects/x/services/healthready",
                  revision: "healthready-1",
                },
              ],
            },
    },
  };
}

test("accepts only byte-identical Console replay", () => {
  const evidence = receipt("console");
  const input = {
    consumer: "console",
    receipt: evidence,
    tag,
    commit,
    artifactBytes,
    live: artifactBytes,
    providerCoordinates: evidence.deployment.providerCoordinates,
  };
  assert.equal(verifyExistingDeployment(input).reused, true);
  assert.throws(
    () => verifyExistingDeployment({ ...input, live: Buffer.from("other") }),
    /live Console/u,
  );
  const moved = structuredClone(evidence.deployment.providerCoordinates);
  moved.sites[1].versionName = "sites/burnbar-console/versions/3";
  assert.throws(
    () => verifyExistingDeployment({ ...input, providerCoordinates: moved }),
    /current console provider coordinates/u,
  );
});

test("accepts only the exact existing Functions revisions and build artifact", () => {
  const evidence = receipt("functions");
  const inventory = {
    schemaVersion: 1,
    targets: ["healthLive", "healthReady"],
  };
  const live = {
    healthLive: {
      domainCore: {
        artifactManifest: { sha256: digest },
        runtime: { service: "healthlive", revision: "healthlive-1" },
      },
    },
    healthReady: {
      domainCore: {
        artifactManifest: { sha256: digest },
        runtime: { service: "healthready", revision: "healthready-1" },
      },
    },
  };
  const input = {
    consumer: "functions",
    receipt: evidence,
    tag,
    commit,
    artifactBytes,
    live,
    providerCoordinates: evidence.deployment.providerCoordinates,
    inventory,
  };
  assert.equal(verifyExistingDeployment(input).reused, true);
  live.healthReady.domainCore.runtime.revision = "stale";
  assert.throws(() => verifyExistingDeployment(input), /live revision/u);
});

test("rejects missing, extra, and mixed current Functions coordinates", () => {
  const evidence = receipt("functions");
  const live = {
    healthLive: {
      domainCore: {
        artifactManifest: { sha256: digest },
        runtime: { service: "healthlive", revision: "healthlive-1" },
      },
    },
    healthReady: {
      domainCore: {
        artifactManifest: { sha256: digest },
        runtime: { service: "healthready", revision: "healthready-1" },
      },
    },
  };
  const inventory = {
    schemaVersion: 1,
    targets: ["healthLive", "healthReady"],
  };
  const base = {
    consumer: "functions",
    receipt: evidence,
    tag,
    commit,
    artifactBytes,
    live,
    inventory,
  };
  assert.throws(
    () =>
      verifyExistingDeployment({
        ...base,
        providerCoordinates: {
          ...evidence.deployment.providerCoordinates,
          targets: evidence.deployment.providerCoordinates.targets.slice(1),
        },
      }),
    /current functions provider coordinates/u,
  );
  assert.throws(
    () =>
      verifyExistingDeployment({
        ...base,
        providerCoordinates: {
          ...evidence.deployment.providerCoordinates,
          targets: [
            ...evidence.deployment.providerCoordinates.targets,
            { target: "extra" },
          ],
        },
      }),
    /current functions provider coordinates/u,
  );
  const mixed = structuredClone(evidence.deployment.providerCoordinates);
  mixed.targets[1].revision = "healthready-2";
  assert.throws(
    () => verifyExistingDeployment({ ...base, providerCoordinates: mixed }),
    /current functions provider coordinates/u,
  );
  assert.throws(
    () =>
      verifyExistingDeployment({
        ...base,
        providerCoordinates: evidence.deployment.providerCoordinates,
        inventory: { schemaVersion: 1, targets: [] },
      }),
    /protected Functions target inventory/u,
  );
});

// Regression: stable replay where the protected candidate C differs from the
// release commit P (the manifest candidate is C, not P). The pre-fix contract
// compared receipt.candidate.candidateCommit to the release commit P and so
// rejected a byte-identical receipt carrying the authoritative candidate C.
// The fix derives authoritativeCandidate from the release gate
// (gate.candidate.candidateCommit) when supplied, falling back to the release
// commit P only when no gate is present. So a byte-identical receipt with the
// correct C is reused, a receipt still carrying P (the old C==P shape) is
// rejected with the authoritative-candidate error, and the legacy ungated
// C==P path is preserved with the generic evidence-mismatch error.
const candidateCommit = "c".repeat(40);
const releaseCommit = "b".repeat(40);

function consoleReceiptWithCandidate(consumerCommit, releaseCommitValue) {
  const base = structuredClone(receipt("console"));
  base.candidate = { candidateCommit: consumerCommit };
  base.release = { tag, commit: releaseCommitValue };
  return base;
}

function protectedReleaseGate(candidateCommitValue, releaseCommitValue) {
  return {
    schemaVersion: 2,
    verificationKind: "domain-core-release-gate",
    candidate: { candidateCommit: candidateCommitValue },
    activation: {
      candidateCommit: candidateCommitValue,
      activationCommit: releaseCommitValue,
      releaseCommit: releaseCommitValue,
    },
    rollbackArtifact: {
      candidate: { candidateCommit: candidateCommitValue },
      activation: {
        candidateCommit: candidateCommitValue,
        activationCommit: releaseCommitValue,
        releaseCommit: releaseCommitValue,
      },
    },
  };
}

const releaseGate = protectedReleaseGate(candidateCommit, releaseCommit);

test("reuses a byte-identical Console receipt whose candidate C differs from release P", () => {
  // C != P: the receipt carries the authoritative candidate C, not the release commit.
  const evidence = consoleReceiptWithCandidate(candidateCommit, releaseCommit);
  const input = {
    consumer: "console",
    receipt: evidence,
    tag,
    commit: releaseCommit,
    artifactBytes,
    live: artifactBytes,
    providerCoordinates: evidence.deployment.providerCoordinates,
    releaseGate,
  };
  assert.equal(verifyExistingDeployment(input).reused, true);
  // Live bytes still must match byte-for-byte.
  assert.throws(
    () => verifyExistingDeployment({ ...input, live: Buffer.from("other") }),
    /live Console/u,
  );
});

test("rejects a Console receipt whose candidate still equals release P when C != P", () => {
  // Old C==P shape: receipt.candidate.candidateCommit == release commit P.
  // When the release gate says the authoritative candidate is C (C != P),
  // this receipt is stale and MUST be rejected with the authoritative-candidate
  // error (the release commit still matches P, only the candidate is wrong).
  const stale = consoleReceiptWithCandidate(releaseCommit, releaseCommit);
  const input = {
    consumer: "console",
    receipt: stale,
    tag,
    commit: releaseCommit,
    artifactBytes,
    live: artifactBytes,
    providerCoordinates: stale.deployment.providerCoordinates,
    releaseGate,
  };
  assert.throws(
    () => verifyExistingDeployment(input),
    /authoritative protected candidate C/u,
  );
});

test("without a release gate, legacy C == P is still required for replay", () => {
  // No --release-gate: authoritativeCandidate falls back to the release commit P,
  // so the old C==P contract is preserved. A receipt whose candidate differs
  // from P must be rejected with the generic evidence-mismatch error (the
  // distinct authoritative-candidate error only fires when a gate is supplied).
  // The byte-identical C==P receipt is still reused without a gate.
  const mismatched = consoleReceiptWithCandidate(candidateCommit, commit);
  const input = {
    consumer: "console",
    receipt: mismatched,
    tag,
    commit,
    artifactBytes,
    live: artifactBytes,
    providerCoordinates: mismatched.deployment.providerCoordinates,
  };
  assert.throws(
    () => verifyExistingDeployment(input),
    /existing evidence does not match the exact stable deployment artifact/u,
  );
  // And the byte-identical C==P receipt is still reused without a gate.
  const legacy = consoleReceiptWithCandidate(commit, commit);
  assert.equal(
    verifyExistingDeployment({
      consumer: "console",
      receipt: legacy,
      tag,
      commit,
      artifactBytes,
      live: artifactBytes,
      providerCoordinates: legacy.deployment.providerCoordinates,
    }).reused,
    true,
  );
});

test("release gate candidate is authoritative even when C == P", () => {
  // When the gate is supplied, its candidate is the source of truth regardless
  // of whether C equals P. A receipt whose candidate matches the gate's C is
  // reused; a receipt whose candidate matches neither the gate's C nor P is
  // rejected with the authoritative-candidate error.
  const gateCandidate = commit;
  const matching = consoleReceiptWithCandidate(gateCandidate, commit);
  assert.equal(
    verifyExistingDeployment({
      consumer: "console",
      receipt: matching,
      tag,
      commit,
      artifactBytes,
      live: artifactBytes,
      providerCoordinates: matching.deployment.providerCoordinates,
      releaseGate: protectedReleaseGate(gateCandidate, commit),
    }).reused,
    true,
  );
  // Candidate differs from BOTH P and the gate's C → rejected.
  const evidence = consoleReceiptWithCandidate("e".repeat(40), releaseCommit);
  assert.throws(
    () =>
      verifyExistingDeployment({
        consumer: "console",
        receipt: evidence,
        tag,
        commit: releaseCommit,
        artifactBytes,
        live: artifactBytes,
        providerCoordinates: evidence.deployment.providerCoordinates,
        releaseGate,
      }),
    /authoritative protected candidate C/u,
  );
});