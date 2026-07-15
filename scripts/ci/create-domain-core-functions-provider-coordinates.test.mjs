import assert from "node:assert/strict";
import test from "node:test";

import { buildFunctionsProviderCoordinates } from "./create-domain-core-functions-provider-coordinates.mjs";

const tag = "v1.2.3";
const commit = "a".repeat(40);
const artifactSha256 = "b".repeat(64);
const inventory = {
  schemaVersion: 1,
  targets: ["healthLive", "insightsHostedAnswer", "onUsageWritten"],
};

function descriptions() {
  return inventory.targets.map((target, index) => ({
    target,
    value: {
      name: `projects/burnbar/locations/us-central1/functions/${target}`,
      state: "ACTIVE",
      buildConfig: {
        build: `projects/burnbar/locations/us-central1/builds/build-${index}`,
        source: {
          storageSource: {
            bucket: "gcf-v2-sources",
            object: "source.zip",
            generation: "42",
          },
        },
      },
      serviceConfig: {
        service: `projects/burnbar/locations/us-central1/services/${target.toLowerCase()}`,
        revision: `${target.toLowerCase()}-00042-abc`,
        environmentVariables: {
          FUNCTION_VERSION: tag,
          OPENBURNBAR_SOURCE_COMMIT: commit,
          OPENBURNBAR_DOMAIN_CORE_RUNTIME_MANIFEST_SHA256: artifactSha256,
        },
      },
    },
  }));
}

test("binds every protected relevant target to one provider source object", () => {
  const result = buildFunctionsProviderCoordinates({
    inventory,
    descriptions: descriptions(),
    tag,
    commit,
    artifactSha256,
  });
  assert.equal(result.targets.length, inventory.targets.length);
  assert.deepEqual(result.sharedSource, {
    bucket: "gcf-v2-sources",
    object: "source.zip",
    generation: "42",
  });
});

test("rejects mixed old/new target source, revision environment, missing and extra targets", () => {
  const mixed = descriptions();
  mixed[2].value.buildConfig.source.storageSource.object = "old-source.zip";
  assert.throws(
    () =>
      buildFunctionsProviderCoordinates({
        inventory,
        descriptions: mixed,
        tag,
        commit,
        artifactSha256,
      }),
    /do not share/u,
  );
  const stale = descriptions();
  stale[1].value.serviceConfig.environmentVariables.OPENBURNBAR_SOURCE_COMMIT =
    "c".repeat(40);
  assert.throws(
    () =>
      buildFunctionsProviderCoordinates({
        inventory,
        descriptions: stale,
        tag,
        commit,
        artifactSha256,
      }),
    /exact release build/u,
  );
  assert.throws(
    () =>
      buildFunctionsProviderCoordinates({
        inventory,
        descriptions: descriptions().slice(1),
        tag,
        commit,
        artifactSha256,
      }),
    /exactly match/u,
  );
  assert.throws(
    () =>
      buildFunctionsProviderCoordinates({
        inventory,
        descriptions: [...descriptions(), descriptions()[0]],
        tag,
        commit,
        artifactSha256,
      }),
    /exactly match/u,
  );
});
