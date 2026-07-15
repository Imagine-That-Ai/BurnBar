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
