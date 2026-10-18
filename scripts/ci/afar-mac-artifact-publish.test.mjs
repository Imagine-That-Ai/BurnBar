import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { publish, PublishError, sha256Hex, validateContract } from "./afar-mac-artifact-publish.mjs";

const root = new URL("../../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");
const committed = JSON.parse(read("config/afar-mac-release.json"));

const ARTIFACT = Buffer.from("afar blank dmg bytes");
const ACCOUNT = "0123456789abcdef0123456789abcdef";
const REPO = "Imagine-That-Ai/BurnBar";
const FEEDS = { "latest-macos.json": Buffer.from('{"version":"1.0.0"}'), "appcast.xml": Buffer.from("<rss/>") };

function contract(overrides = {}) {
  const sha = sha256Hex(ARTIFACT);
  return {
    ...committed,
    artifact: { ...committed.artifact, sha256: sha, size: ARTIFACT.length },
    cleanGuiAcceptance: {
      accepted: true,
      installedArtifactSha256: sha,
      evidenceSha256: "e".repeat(64),
      acceptedAt: "2026-10-19T00:00:00Z"
    },
    ...overrides
  };
}

function response(status, body = Buffer.alloc(0), headers = {}) {
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (name) => headers[name.toLowerCase()] ?? null },
    json: async () => JSON.parse(body.toString()),
    arrayBuffer: async () => body
  };
}

/** A fake GitHub + public host + R2 bucket. */
function world({ draft = true, assetBytes = ARTIFACT, bucketProbe = FEEDS["latest-macos.json"], existing = null, changeFeedOnPut = false } = {}) {
  const sha = sha256Hex(ARTIFACT);
  const c = contract();
  const objects = new Map(Object.entries(FEEDS));
  if (existing) objects.set(c.objectKey, existing);
  const calls = { aws: [], fetch: [], tokenOffOrigin: false };
  const fetchImpl = async (url, init = {}) => {
    calls.fetch.push(url);
    const auth = init.headers?.Authorization;
    if (url.startsWith("https://api.github.com/repos/")) {
      if (url.includes("/releases?")) {
        const release = {
          tag_name: c.draftReleaseTag,
          draft,
          assets: [{ name: c.artifact.fileName, size: assetBytes.length, url: `https://api.github.com/repos/${REPO}/releases/assets/1` }]
        };
        return response(200, Buffer.from(JSON.stringify([release])));
      }
      return response(302, Buffer.alloc(0), { location: "https://objects.githubusercontent.com/blob" });
    }
    if (url.startsWith("https://objects.githubusercontent.com/")) {
      if (auth) calls.tokenOffOrigin = true;
      return response(200, assetBytes);
    }
    if (url.startsWith("https://downloads.burnbar.ai/")) {
      if (auth) calls.tokenOffOrigin = true;
      const key = url.slice("https://downloads.burnbar.ai/".length).split("?")[0];
      return objects.has(key) ? response(200, objects.get(key)) : response(404);
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  const runAws = (args) => {
    calls.aws.push(args);
    const value = (flag) => args[args.indexOf(flag) + 1];
    if (args[1] === "get-object") {
      writeFileSync(args[args.length - 1], bucketProbe);
      return { status: 0, stdout: "{}", stderr: "" };
    }
    if (args[1] === "put-object") {
      const key = value("--key");
      if (objects.has(key)) {
        return { status: 254, stdout: "", stderr: "An error occurred (PreconditionFailed) when calling the PutObject operation" };
      }
      objects.set(key, readFileSync(value("--body")));
      if (changeFeedOnPut) objects.set("appcast.xml", Buffer.from("<rss changed/>"));
      return { status: 0, stdout: "{}", stderr: "" };
    }
    return { status: 1, stdout: "", stderr: "unexpected" };
  };
  return { c, sha, calls, objects, fetchImpl, runAws };
}

async function run(w, overrides = {}) {
  return publish({
    contractRaw: overrides.contractRaw ?? w.c,
    repository: REPO,
    token: "ghs_test",
    accountId: ACCOUNT,
    fetchImpl: w.fetchImpl,
    runAws: w.runAws,
    workDir: mkdtempSync(join(tmpdir(), "afar-publish-test-")),
    sleep: async () => {}
  });
}

const puts = (w) => w.calls.aws.filter((args) => args[1] === "put-object");

test("the committed contract pins the exact blank DMG and stays unaccepted", () => {
  const c = validateContract(committed);
  assert.equal(c.sha256, "9e46f299de73cb6510ed8b49f9a32cb7758b98e593fe51b8e568b06bd68aa272");
  assert.equal(c.size, 40624316);
  assert.equal(c.publicUrl, "https://downloads.burnbar.ai/mission-control/0.1.12/MissionControl-blank-0.1.12-universal-release.dmg");
  assert.equal(committed.cleanGuiAcceptance.accepted, false);
  assert.throws(() => validateContract(committed, { requireAccepted: true }), /acceptance is not recorded/);
});

test("acceptance must name the exact artifact and carry evidence", () => {
  const base = contract();
  for (const acceptance of [
    { ...base.cleanGuiAcceptance, accepted: "true" },
    { ...base.cleanGuiAcceptance, installedArtifactSha256: "f".repeat(64) },
    { ...base.cleanGuiAcceptance, evidenceSha256: null },
    { ...base.cleanGuiAcceptance, acceptedAt: "yesterday" }
  ]) {
    assert.throws(() => validateContract({ ...base, cleanGuiAcceptance: acceptance }, { requireAccepted: true }), PublishError);
  }
});

test("every binding field is pinned, so a changed key, bucket or host fails closed", () => {
  for (const change of [
    { objectKey: "latest-macos.json" },
    { objectKey: "mission-control/0.1.12/other.dmg" },
    { bucket: "another-bucket" },
    { publicBaseUrl: "https://example.com" },
    { draftReleaseTag: "v0.1.12" },
    { bindingProbeKey: "appcast.xml" },
    { artifact: { ...committed.artifact, fileName: "MissionControl-personal-0.1.12.dmg" } },
    { product: "OpenBurnBar" }
  ]) {
    assert.throws(() => validateContract({ ...committed, ...change }), PublishError, JSON.stringify(change));
  }
});

test("publishes one conditional object and verifies it publicly", async () => {
  const w = world();
  const receipt = await run(w);
  assert.equal(receipt.result, "published");
  assert.equal(puts(w).length, 1);
  const args = puts(w)[0];
  assert.equal(args[args.indexOf("--key") + 1], w.c.objectKey);
  assert.equal(args[args.indexOf("--bucket") + 1], "openburnbar-downloads");
  assert.equal(args[args.indexOf("--if-none-match") + 1], "*");
  assert.equal(args[args.indexOf("--checksum-sha256") + 1], Buffer.from(w.sha, "hex").toString("base64"));
  assert.equal(args[args.indexOf("--endpoint-url") + 1], `https://${ACCOUNT}.r2.cloudflarestorage.com`);
  assert.deepEqual(w.calls.aws.map((a) => a[1]), ["get-object", "put-object"]);
  assert.equal(w.calls.tokenOffOrigin, false);
  assert.equal(w.objects.get("latest-macos.json"), FEEDS["latest-macos.json"]);
});

test("refuses without acceptance before any network or bucket access", async () => {
  const w = world();
  await assert.rejects(run(w, { contractRaw: committed }), /acceptance is not recorded/);
  assert.equal(w.calls.fetch.length, 0);
  assert.equal(w.calls.aws.length, 0);
});

test("refuses a published (public) staging release", async () => {
  const w = world({ draft: false });
  await assert.rejects(run(w), /not a draft/);
  assert.equal(w.calls.aws.length, 0);
});

test("refuses staged bytes that differ from the contract", async () => {
  const w = world({ assetBytes: Buffer.from("afar blank dmg byteZ") });
  await assert.rejects(run(w), /SHA-256 does not match/);
  assert.equal(w.calls.aws.length, 0);
});

test("refuses to write when the bucket is not the one behind the public host", async () => {
  const w = world({ bucketProbe: Buffer.from("different bucket") });
  await assert.rejects(run(w), /disagree on the binding probe/);
  assert.equal(puts(w).length, 0);
});

test("an existing identical object is reported, never overwritten", async () => {
  const w = world({ existing: ARTIFACT });
  const receipt = await run(w);
  assert.equal(receipt.result, "already-published");
  assert.equal(puts(w).length, 1);
});

test("an existing different object is a conflict and is left untouched", async () => {
  const other = Buffer.from("someone else's bytes");
  const w = world({ existing: other });
  await assert.rejects(run(w), /conflict, not overwritten/);
  assert.equal(w.objects.get(w.c.objectKey), other);
});

test("fails if an OpenBurnBar feed changes during publication", async () => {
  const w = world({ changeFeedOnPut: true });
  await assert.rejects(run(w), /feed appcast.xml changed/);
});

test("the workflow is dispatch-only, main-only, pinned and scoped to the release environment", () => {
  const wf = read(".github/workflows/publish-afar-mac-artifact.yml");
  assert.match(wf, /^on:\n  workflow_dispatch:\n/m);
  assert.doesNotMatch(wf, /^\s+(push|pull_request|pull_request_target|schedule|release|workflow_run):/m);
  assert.match(wf, /^permissions: \{\}$/m);
  assert.match(wf, /if: github\.ref == 'refs\/heads\/main'/);
  assert.match(wf, /environment: release$/m);
  assert.equal((wf.match(/contents: write/g) ?? []).length, 1);
  assert.doesNotMatch(wf, /(actions|id-token|packages|pull-requests|deployments): write/);
  for (const [, ref] of wf.matchAll(/uses:\s*[^@\s]+@(\S+)/g)) assert.match(ref, /^[0-9a-f]{40}$/);
  assert.match(wf, /persist-credentials: false/);
  assert.match(wf, /options:\n\s+- config\/afar-mac-release\.json\n/);
  assert.match(wf, /--require-hashes --only-binary=:all: --no-deps/);
  assert.equal((wf.match(/GH_TOKEN:/g) ?? []).length, 1);
  assert.doesNotMatch(wf, /CLOUDFLARE_API_TOKEN|upload-macos-downloads-r2|setup-macos-downloads-r2|appcast|latest-macos|gh release (create|upload|edit|delete)/);
  // Inputs and secrets reach shell steps only through env, never interpolated into run.
  assert.doesNotMatch(wf, /run:.*\$\{\{/);
});

test("the AWS CLI requirements are fully hash-pinned", () => {
  const lines = read("scripts/ci/afar-mac-awscli-requirements.txt").split("\n").filter((l) => /^[a-z]/i.test(l));
  assert.ok(lines.some((l) => l.startsWith("awscli==1.46.1 ")));
  for (const line of lines) assert.match(line, /^[a-z0-9-]+==[\w.]+ \\$/);
  assert.equal((read("scripts/ci/afar-mac-awscli-requirements.txt").match(/--hash=sha256:[0-9a-f]{64}/g) ?? []).length, lines.length);
});
