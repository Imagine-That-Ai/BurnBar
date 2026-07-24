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
// The fix compares receipt.candidate.candidateCommit to the authoritative
// candidate C from the release gate (gate.candidate.candidateCommit), so a
// byte-identical receipt with the correct C is reused and a receipt still
// carrying P (the old C==P shape) is rejected.
const candidateCommit = "c".repeat(40);
const releaseCommit = "b".repeat(40);

function consoleReceiptWithCandidate(consumerCommit, releaseCommitValue) {
  const base = structuredClone(receipt("console"));
  base.candidate = { candidateCommit: consumerCommit };
  base.release = { tag, commit: releaseCommitValue };
  return base;
}

const releaseGate = {
  schemaVersion: 1,
  candidate: { candidateCommit },
  release: { tag, commit: releaseCommit },
};

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
  // this receipt is stale and MUST be rejected.
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
    /candidate/u,
  );
});

test("ignores the release gate candidate when C == P (ungated legacy receipt still matches)", () => {
  // When candidate C equals release commit P, the existing C==P receipt is
  // still byte-identical and reused regardless of the gate; the gate is only
  // consulted when C != P.
  const evidence = consoleReceiptWithCandidate(commit, commit);
  const input = {
    consumer: "console",
    receipt: evidence,
    tag,
    commit,
    artifactBytes,
    live: artifactBytes,
    providerCoordinates: evidence.deployment.providerCoordinates,
    releaseGate: {
      schemaVersion: 1,
      candidate: { candidateCommit: "d".repeat(40) },
      release: { tag, commit },
    },
  };
  assert.equal(verifyExistingDeployment(input).reused, true);
});

test("release gate candidate must match the receipt candidate when C != P", () => {
  // The gate's candidate is the source of truth. A receipt whose candidate
  // differs from BOTH P and the gate's C must be rejected.
  const evidence = consoleReceiptWithCandidate("e".repeat(40), releaseCommit);
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
  assert.throws(
    () => verifyExistingDeployment(input),
    /candidate/u,
  );
});
