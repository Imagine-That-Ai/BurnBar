import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { verifyExistingDeployment } from "./verify-existing-domain-core-deployment.mjs";

const candidate = Object.freeze({
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
});
const activation = Object.freeze({
  ...candidate,
  activationCommit: "c".repeat(40),
  changedPathsSha256: "d".repeat(64),
});
const commit = "e".repeat(40);
const tag = "v1.2.3";

function functionsIdentity() {
  return {
    source: {
      repository: "https://github.com/Imagine-That-Ai/BurnBar",
      commit,
    },
    candidateIdentity: structuredClone(candidate),
    loadedCore: {
      version: candidate.coreVersion,
      abiVersion: candidate.abiVersion,
      sourceSha256: candidate.sourceSha256,
      wasmSha256: "9".repeat(64),
    },
  };
}

function artifact(consumer, candidateIdentity = candidate) {
  return Buffer.from(
    `${JSON.stringify({
      schemaVersion: 1,
      manifestKind: "domain-core-runtime-artifact",
      consumer,
      profile: "public-production",
      candidate: candidateIdentity,
      files: [],
    })}\n`,
  );
}

function receipt(consumer) {
  const artifactBytes = artifact(consumer);
  const artifactSha256 = createHash("sha256")
    .update(artifactBytes)
    .digest("hex");
  return {
    schemaVersion: 2,
    consumer,
    candidate: structuredClone(candidate),
    activation: structuredClone(activation),
    sourceRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/domain-core.yml",
      runId: 101,
      runAttempt: 2,
      event: "push",
      ref: "refs/heads/main",
      headSha: candidate.candidateCommit,
    },
    promotionProof: {
      signerWorkflow: ".github/workflows/domain-core-promotion-proof.yml",
      predicateType: "https://slsa.dev/provenance/v1",
      signerRun: { runId: 202, runAttempt: 3 },
    },
    rollbackArtifact: {
      fileName: "domain-core-public-production-rollback.json",
      sha256: "f".repeat(64),
      candidate: structuredClone(candidate),
      activation: structuredClone(activation),
    },
    release: { tag, commit },
    deployment: {
      status: "healthy",
      deployedArtifact: { sha256: artifactSha256 },
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
              buildArtifactSha256: artifactSha256,
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
  const artifactBytes = artifact("console");
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
  const artifactBytes = artifact("functions");
  const digest = createHash("sha256").update(artifactBytes).digest("hex");
  const inventory = {
    schemaVersion: 1,
    targets: ["healthLive", "healthReady"],
  };
  const live = {
    healthLive: {
      source: functionsIdentity().source,
      domainCore: {
        candidateIdentity: functionsIdentity().candidateIdentity,
        loadedCore: functionsIdentity().loadedCore,
        artifactManifest: { sha256: digest },
        runtime: { service: "healthlive", revision: "healthlive-1" },
      },
    },
    healthReady: {
      source: functionsIdentity().source,
      domainCore: {
        candidateIdentity: functionsIdentity().candidateIdentity,
        loadedCore: functionsIdentity().loadedCore,
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
  const artifactBytes = artifact("functions");
  const digest = createHash("sha256").update(artifactBytes).digest("hex");
  const live = {
    healthLive: {
      source: functionsIdentity().source,
      domainCore: {
        candidateIdentity: functionsIdentity().candidateIdentity,
        loadedCore: functionsIdentity().loadedCore,
        artifactManifest: { sha256: digest },
        runtime: { service: "healthlive", revision: "healthlive-1" },
      },
    },
    healthReady: {
      source: functionsIdentity().source,
      domainCore: {
        candidateIdentity: functionsIdentity().candidateIdentity,
        loadedCore: functionsIdentity().loadedCore,
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

test("replays distinct candidate C activation P and release D without weakening gate binding", () => {
  for (const consumer of ["console", "functions"]) {
    const evidence = receipt(consumer);
    const artifactBytes = artifact(consumer);
    const providerCoordinates = evidence.deployment.providerCoordinates;
    const inventory =
      consumer === "functions"
        ? { schemaVersion: 1, targets: ["healthLive", "healthReady"] }
        : undefined;
    const live =
      consumer === "console"
        ? artifactBytes
        : Object.fromEntries(
            providerCoordinates.targets.map((target) => [
              target.target,
              {
                source: functionsIdentity().source,
                domainCore: {
                  candidateIdentity: functionsIdentity().candidateIdentity,
                  loadedCore: functionsIdentity().loadedCore,
                  artifactManifest: {
                    sha256: evidence.deployment.deployedArtifact.sha256,
                  },
                  runtime: {
                    service: target.service.split("/").at(-1),
                    revision: target.revision,
                  },
                },
              },
            ]),
          );
    const input = {
      consumer,
      receipt: evidence,
      tag,
      commit,
      artifactBytes,
      live,
      providerCoordinates,
      inventory,
    };
    assert.equal(verifyExistingDeployment(input).reused, true);
    assert.notEqual(evidence.candidate.candidateCommit, commit);
    assert.notEqual(evidence.activation.activationCommit, commit);

    const mutations = [
      [
        "release D",
        (value) => {
          value.release.commit = activation.activationCommit;
        },
      ],
      [
        "source candidate C",
        (value) => {
          value.sourceRun.headSha = commit;
        },
      ],
      [
        "rollback activation P",
        (value) => {
          value.rollbackArtifact.activation.activationCommit = commit;
        },
      ],
      [
        "candidate tuple",
        (value) => {
          value.candidate.coreVersion = "0.4.0";
        },
      ],
    ];
    for (const [label, mutate] of mutations) {
      const substituted = structuredClone(evidence);
      mutate(substituted);
      assert.throws(
        () => verifyExistingDeployment({ ...input, receipt: substituted }),
        undefined,
        `${consumer}: ${label}`,
      );
    }
    assert.throws(() =>
      verifyExistingDeployment({
        ...input,
        artifactBytes: artifact(consumer, {
          ...candidate,
          sourceSha256: "0".repeat(64),
        }),
      }),
    );
    if (consumer === "functions") {
      const staleCandidate = structuredClone(live);
      staleCandidate.healthReady.domainCore.candidateIdentity.sourceSha256 =
        "0".repeat(64);
      assert.throws(() =>
        verifyExistingDeployment({ ...input, live: staleCandidate }),
      );
      const staleRelease = structuredClone(live);
      staleRelease.healthLive.source.commit = activation.activationCommit;
      assert.throws(() =>
        verifyExistingDeployment({ ...input, live: staleRelease }),
      );
    }
  }
});
