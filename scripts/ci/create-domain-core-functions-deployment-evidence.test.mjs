import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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
  loadedCore: {
    version: CANDIDATE.coreVersion,
    abiVersion: CANDIDATE.abiVersion,
    sourceSha256: CANDIDATE.sourceSha256,
    wasmSha256: "9".repeat(64),
  },
  artifactManifest: {
    fileName: "domain-core-runtime-artifact-manifest.json",
    sha256: "8".repeat(64),
  },
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
    runtimeArtifact: {
      fileName: "domain-core-runtime-artifact-manifest.json",
      sha256: "8".repeat(64),
      value: {
        files: [
          {
            path: "vendor/openburnbar/domain-core-wasm/openburnbar_domain_core_bg.wasm",
            sha256: "9".repeat(64),
          },
        ],
      },
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
    healthLive: {
      status: "alive",
      source,
      domainCore: {
        ...DOMAIN_CORE,
        runtime: {
          service: "healthlive",
          revision: "healthlive-1",
          configuration: "healthlive",
          functionTarget: "healthLive",
        },
      },
    },
    healthReady: {
      status: "ready",
      version: "v1.2.3",
      source,
      domainCore: {
        ...DOMAIN_CORE,
        runtime: {
          service: "healthready",
          revision: "healthready-1",
          configuration: "healthready",
          functionTarget: "healthReady",
        },
      },
      sentry: { enabled: true, environment: "production" },
    },
  };
}

function providerCoordinates() {
  return {
    buildArtifactSha256: "8".repeat(64),
    sharedSource: { bucket: "sources", object: "source.zip", generation: "42" },
    targets: [
      {
        target: "healthLive",
        function: "functions/healthLive",
        build: "builds/1",
        service: "services/healthlive",
        revision: "healthlive-1",
      },
      {
        target: "healthReady",
        function: "functions/healthReady",
        build: "builds/1",
        service: "services/healthready",
        revision: "healthready-1",
      },
    ],
  };
}

const inventory = {
  schemaVersion: 1,
  targets: ["healthLive", "healthReady"],
};

function runVerification() {
  return {
    schemaVersion: 1,
    verificationKind: "domain-core-functions-deploy-run",
    deployRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/deploy-production.yml",
      runId: 303,
      runAttempt: 4,
      event: "push",
      ref: "refs/tags/v1.2.3",
      headSha: CANDIDATE.candidateCommit,
      jobSetSha256: "f".repeat(64),
    },
  };
}

function healthBytes(value = health()) {
  return Buffer.from(`${JSON.stringify(value)}\n`);
}

test("turns exact live deployment proof into v2 generator input", () => {
  const bytes = healthBytes();
  const evidence = createFunctionsDeploymentEvidence(
    proof(),
    health(),
    runVerification(),
    bytes,
    providerCoordinates(),
    inventory,
  );
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
    deployedArtifact: {
      fileName: proof().runtimeArtifact.fileName,
      sha256: proof().runtimeArtifact.sha256,
    },
    providerCoordinates: providerCoordinates(),
    deployRun: runVerification().deployRun,
    healthArtifactSha256: createHash("sha256").update(bytes).digest("hex"),
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
    assert.throws(() =>
      createFunctionsDeploymentEvidence(
        proof(),
        value,
        runVerification(),
        healthBytes(value),
        providerCoordinates(),
        inventory,
      ),
    );
  }
});

test("rejects deploy-run coordinate and job-set substitutions", () => {
  const cases = [
    (value) => {
      value.deployRun.runId += 1;
    },
    (value) => {
      value.deployRun.runAttempt += 1;
    },
    (value) => {
      value.deployRun.ref = "refs/tags/v1.2.2";
    },
    (value) => {
      value.deployRun.headSha = "0".repeat(40);
    },
    (value) => {
      value.deployRun.jobSetSha256 = "invalid";
    },
  ];
  for (const mutate of cases) {
    const value = runVerification();
    mutate(value);
    assert.throws(() =>
      createFunctionsDeploymentEvidence(
        proof(),
        health(),
        value,
        healthBytes(),
        providerCoordinates(),
        inventory,
      ),
    );
  }
});

test("rejects missing, extra, and duplicate protected target coordinates", () => {
  const cases = [
    providerCoordinates().targets.slice(1),
    [...providerCoordinates().targets, { target: "extra" }],
    [providerCoordinates().targets[0], providerCoordinates().targets[0]],
  ];
  for (const targets of cases) {
    assert.throws(() =>
      createFunctionsDeploymentEvidence(
        proof(),
        health(),
        runVerification(),
        healthBytes(),
        { ...providerCoordinates(), targets },
        inventory,
      ),
    );
  }
});
