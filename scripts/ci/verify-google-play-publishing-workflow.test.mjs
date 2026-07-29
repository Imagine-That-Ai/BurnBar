import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const release = readFileSync(
  new URL("../../.github/workflows/release.yml", import.meta.url),
  "utf8",
);
const domainCore = readFileSync(
  new URL("../../.github/workflows/domain-core.yml", import.meta.url),
  "utf8",
);

function workflowJob(source, name, nextName) {
  const start = source.indexOf(`\n  ${name}:`);
  assert.notEqual(start, -1, `missing workflow job ${name}`);
  const end = nextName ? source.indexOf(`\n  ${nextName}:`, start + 1) : -1;
  return source.slice(start, end === -1 ? source.length : end);
}

test("release workflow publishes only the exact verified AAB through the protected release environment", () => {
  const publish = workflowJob(
    release,
    "publish-google-play-internal",
    "verify-live-update-feed",
  );
  assert.match(
    publish,
    /needs:[\s\S]*- release-preflight[\s\S]*- build-and-release[\s\S]*- domain-core-native-release-evidence/u,
  );
  assert.match(publish, /environment: release/u);
  assert.match(publish, /permissions:\n\s+actions: read\n\s+contents: read/u);
  assert.doesNotMatch(publish, /continue-on-error/u);
  assert.match(
    publish,
    /ref: \$\{\{ needs\.release-preflight\.outputs\.release_commit \}\}[\s\S]*persist-credentials: false/u,
  );
  assert.match(
    publish,
    /name: \$\{\{ needs\.build-and-release\.outputs\.aab_name \}\}/u,
  );
  assert.match(publish, /bundletool-all-1\.18\.3\.jar/u);
  assert.match(
    publish,
    /a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29/u,
  );
  assert.match(publish, /bundletool" validate --bundle="\$AAB_PATH"/u);
  assert.match(publish, /--xpath=\/manifest\/@android:versionName/u);
  assert.match(publish, /--xpath=\/manifest\/@android:versionCode/u);
  assert.match(
    publish,
    /GOOGLE_PLAY_SERVICE_ACCOUNT_JSON: \$\{\{ secrets\.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON \}\}/u,
  );
  assert.match(
    publish,
    /publish-internal-release\.mjs[\s\S]*--expected-version-code "\$VERSION_CODE"[\s\S]*--confirm-google-play-publish burnbar-google-play-internal/u,
  );
  assert.match(publish, /retention-days: 365/u);
});

test("Google Play publisher and workflow contracts run in PR and release gates", () => {
  const promotion = workflowJob(
    domainCore,
    "promotion-contracts",
    "candidate-bundle",
  );
  assert.match(
    promotion,
    /tools\/google-play\/test-publish-internal-release\.mjs/u,
  );
  assert.match(
    promotion,
    /scripts\/ci\/verify-google-play-publishing-workflow\.test\.mjs/u,
  );

  const supplyChain = workflowJob(
    release,
    "release-supply-chain-gate",
    "release-preflight",
  );
  assert.match(
    supplyChain,
    /tools\/google-play\/test-publish-internal-release\.mjs/u,
  );
  assert.match(
    supplyChain,
    /scripts\/ci\/verify-google-play-publishing-workflow\.test\.mjs/u,
  );
});
