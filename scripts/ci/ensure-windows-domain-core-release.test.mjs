import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  GhReleaseClient,
  manageRelease,
  validateRequest,
} from "./ensure-windows-domain-core-release.mjs";

const request = {
  repository: "Imagine-That-Ai/BurnBar",
  tag: "windows-v1.2.3",
  commit: "a".repeat(40),
  phase: "prepare",
};
const script = fileURLToPath(
  new URL("./ensure-windows-domain-core-release.mjs", import.meta.url),
);
const published = {
  tag_name: request.tag,
  draft: false,
  prerelease: false,
};
const draft = { ...published, draft: true };

class FakeClient {
  constructor({ lookups = [null], create = true, publish = true } = {}) {
    this.lookupValues = [...lookups];
    this.lastLookup = this.lookupValues.at(-1) ?? null;
    this.createResult = create;
    this.publishResult = publish;
    this.creates = 0;
    this.publishes = 0;
    this.lookups = 0;
  }

  lookup() {
    this.lookups += 1;
    return this.lookupValues.length > 0
      ? this.lookupValues.shift()
      : this.lastLookup;
  }

  createDraft(value) {
    this.creates += 1;
    assert.equal(value.version, "1.2.3");
    return this.createResult;
  }

  publish(value) {
    this.publishes += 1;
    assert.equal(value.version, "1.2.3");
    return this.publishResult;
  }
}

test("prepare reuses an exact draft or published release without mutation", () => {
  for (const release of [draft, published]) {
    const client = new FakeClient({ lookups: [release] });
    assert.deepEqual(manageRelease(request, client), {
      created: false,
      draft: release.draft,
    });
    assert.equal(client.creates, 0);
  }
});

test("prepare creates a missing exact release as a draft", () => {
  const client = new FakeClient();
  assert.deepEqual(manageRelease(request, client), {
    created: true,
    draft: true,
  });
  assert.equal(client.creates, 1);
});

test("prepare rejects prerelease and wrong-tag releases", () => {
  for (const release of [
    { ...published, prerelease: true },
    { ...published, tag_name: "windows-v1.2.4" },
  ]) {
    assert.throws(() =>
      manageRelease(request, new FakeClient({ lookups: [release] })),
    );
  }
});

test("a draft creation collision succeeds only when the winner is exact", () => {
  assert.deepEqual(
    manageRelease(
      request,
      new FakeClient({ lookups: [null, draft], create: false }),
    ),
    { created: false, draft: true },
  );
  assert.throws(() =>
    manageRelease(
      request,
      new FakeClient({
        lookups: [null, { ...draft, prerelease: true }],
        create: false,
      }),
    ),
  );
  assert.throws(
    () =>
      manageRelease(
        request,
        new FakeClient({ lookups: [null, null], create: false }),
      ),
    /draft creation failed/,
  );
});

test("publish exposes a draft only after successful final verification", () => {
  const client = new FakeClient({ lookups: [draft, published] });
  assert.deepEqual(manageRelease({ ...request, phase: "publish" }, client), {
    published: true,
    alreadyPublished: false,
  });
  assert.equal(client.publishes, 1);

  const rerun = new FakeClient({ lookups: [published] });
  assert.deepEqual(manageRelease({ ...request, phase: "publish" }, rerun), {
    published: false,
    alreadyPublished: true,
  });
  assert.equal(rerun.publishes, 0);
});

test("publish failure accepts only a concurrently published exact release", () => {
  assert.deepEqual(
    manageRelease(
      { ...request, phase: "publish" },
      new FakeClient({ lookups: [draft, published], publish: false }),
    ),
    { published: false, alreadyPublished: true },
  );
  assert.throws(() =>
    manageRelease(
      { ...request, phase: "publish" },
      new FakeClient({ lookups: [draft, draft], publish: false }),
    ),
  );
});

test("request identity rejects repository, tag, commit, and field substitution", () => {
  assert.throws(
    () => validateRequest({ ...request, repository: "owner/fork" }),
    /repository/,
  );
  assert.throws(() => validateRequest({ ...request, tag: "v1.2.3" }), /tag/);
  assert.throws(
    () => validateRequest({ ...request, tag: "windows-v1.2.3+build.1" }),
    /tag/,
  );
  assert.throws(
    () => validateRequest({ ...request, commit: "A".repeat(40) }),
    /commit/,
  );
  assert.throws(() => validateRequest({ ...request, extra: true }), /contain/);
  assert.throws(
    () => validateRequest({ ...request, phase: "unknown" }),
    /phase/,
  );
});

test("GitHub client distinguishes absence and separates draft creation from publication", () => {
  const commands = [];
  const responses = [
    { status: 1, stdout: "", stderr: "gh: Not Found (HTTP 404)" },
    { status: 1, stdout: "", stderr: "gh: service unavailable (HTTP 503)" },
    { status: 0, stdout: "", stderr: "" },
    { status: 0, stdout: "", stderr: "" },
  ];
  const runner = (_command, arguments_) => {
    commands.push(arguments_);
    return responses.shift();
  };
  const client = new GhReleaseClient(request.repository, runner);
  assert.equal(client.lookup(request.tag), null);
  assert.throws(() => client.lookup(request.tag), /503/);
  assert.equal(client.createDraft({ ...request, version: "1.2.3" }), true);
  assert.equal(client.publish({ ...request, version: "1.2.3" }), true);
  const create = commands[2];
  assert.deepEqual(create.slice(0, 3), ["release", "create", request.tag]);
  assert.ok(create.includes("--verify-tag"));
  assert.ok(create.includes("--latest=false"));
  assert.ok(create.includes("--draft"));
  const publish = commands[3];
  assert.deepEqual(publish.slice(0, 3), ["release", "edit", request.tag]);
  assert.ok(publish.includes("--draft=false"));
  assert.ok(publish.includes("--latest=false"));
  assert.ok(!commands.flat().includes("--clobber"));
});

test("CLI validates once and prepares an absent exact draft", () => {
  const root = mkdtempSync(join(tmpdir(), "windows-release-cli-test-"));
  try {
    const bin = join(root, "bin");
    mkdirSync(bin);
    const gh = join(bin, "gh");
    writeFileSync(
      gh,
      `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === "api") {
  process.stderr.write("gh: Not Found (HTTP 404)\\n");
  process.exit(1);
}
if (args[0] === "release" && args[1] === "create") process.exit(0);
process.exit(2);
`,
    );
    chmodSync(gh, 0o755);
    const result = spawnSync(
      process.execPath,
      [
        script,
        "--repository",
        request.repository,
        "--tag",
        request.tag,
        "--commit",
        request.commit,
        "--phase",
        "prepare",
      ],
      {
        encoding: "utf8",
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      ok: true,
      created: true,
      draft: true,
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
