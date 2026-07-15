import assert from "node:assert/strict";
import test from "node:test";

import { createFunctionsDeploymentEvidence } from "./create-domain-core-functions-deployment-evidence.mjs";

const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};
const DOMAIN_CORE = {
  profile: "public-production",
  candidateIdentity: CANDIDATE,
  pricingMode: "rust",
};

function proof() {
  return {
    schemaVersion: 1,
    proofKind: "domain-core-functions-deploy-proof",
    repository: "Imagine-That-Ai/BurnBar",
    workflowPath: ".github/workflows/deploy-production.yml",
    deployRun: { runId: 303, runAttempt: 4 },
    release: { tag: "v1.2.3", commit: CANDIDATE.candidateCommit },
    profile: {
      value: {
        name: "public-production",
        candidateIdentity: CANDIDATE,
        modes: { pricing: "rust" },
      },
      sha256: "c".repeat(64),
      canonicalSha256: "d".repeat(64),
    },
    compiledReceipt: {
      fileName: "domainCoreCandidateReceipt.js",
      sha256: "e".repeat(64),
    },
    releaseGate: {
      fileName: "domain-core-release-gate.json",
      sha256: "f".repeat(64),
    },
  };
}

function health() {
  const source = {
    repository: "https://github.com/Imagine-That-Ai/BurnBar",
    commit: CANDIDATE.candidateCommit,
  };
  return {
    project: "burnbar",
    tag: "v1.2.3",
    healthLive: { status: "alive", source, domainCore: DOMAIN_CORE },
    healthReady: {
      status: "ready",
      version: "v1.2.3",
      source,
      domainCore: DOMAIN_CORE,
      sentry: { enabled: true, environment: "production" },
    },
  };
}

test("turns exact live deployment proof into v2 generator input", () => {
  const evidence = createFunctionsDeploymentEvidence(proof(), health());
  assert.deepEqual(evidence, {
    provider: "firebase-functions",
    project: "burnbar",
    environment: "production",
    status: "healthy",
    healthChecks: [
      "healthLive",
      "healthReady",
      "sourceCommit",
      "functionVersion",
      "sentry",
      "domainCoreProfile",
    ],
    deployedArtifact: proof().compiledReceipt,
  });
});

test("rejects stale source, profile, version, and Sentry identities", () => {
  const cases = [
    (value) => {
      value.healthLive.source.commit = "0".repeat(40);
    },
    (value) => {
      value.healthReady.domainCore.pricingMode = "legacy";
    },
    (value) => {
      value.healthLive.domainCore.candidateIdentity.sourceSha256 = "0".repeat(
        64,
      );
    },
    (value) => {
      value.healthReady.version = "v1.2.2";
    },
    (value) => {
      value.healthReady.sentry.enabled = false;
    },
  ];
  for (const mutate of cases) {
    const value = structuredClone(health());
    mutate(value);
    assert.throws(() => createFunctionsDeploymentEvidence(proof(), value));
  }
});
