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
  ensureRelease,
  GhReleaseClient,
  validateRequest,
} from "./ensure-windows-domain-core-release.mjs";

const request = {
  repository: "Imagine-That-Ai/BurnBar",
  tag: "windows-v1.2.3",
  commit: "a".repeat(40),
};
const script = fileURLToPath(
  new URL("./ensure-windows-domain-core-release.mjs", import.meta.url),
);
const published = {
  tag_name: request.tag,
  draft: false,
  prerelease: false,
};

class FakeClient {
  constructor({ release = null, create = true, concurrent = null } = {}) {
    this.release = release;
    this.createResult = create;
    this.concurrent = concurrent;
    this.creates = 0;
    this.lookups = 0;
  }

  lookup() {
    this.lookups += 1;
    return this.lookups === 1 ? this.release : this.concurrent;
  }

  create(value) {
    this.creates += 1;
    assert.equal(value.version, "1.2.3");
    return this.createResult;
  }
}

test("an exact existing published release is reused without mutation", () => {
  const client = new FakeClient({ release: published });
  assert.deepEqual(ensureRelease(request, client), { created: false });
  assert.equal(client.creates, 0);
});

test("a missing exact release is created as a normal published release", () => {
  const client = new FakeClient();
  assert.deepEqual(ensureRelease(request, client), { created: true });
  assert.equal(client.creates, 1);
});

test("draft, prerelease, and wrong-tag releases fail closed", () => {
  for (const release of [
    { ...published, draft: true },
    { ...published, prerelease: true },
    { ...published, tag_name: "windows-v1.2.4" },
  ]) {
    assert.throws(() => ensureRelease(request, new FakeClient({ release })));
  }
});

test("a creation collision succeeds only when the winner is exact", () => {
  assert.deepEqual(
    ensureRelease(
      request,
      new FakeClient({ create: false, concurrent: published }),
    ),
    { created: false },
  );
  assert.throws(() =>
    ensureRelease(
      request,
      new FakeClient({
        create: false,
        concurrent: { ...published, draft: true },
      }),
    ),
  );
  assert.throws(
    () => ensureRelease(request, new FakeClient({ create: false })),
    /creation failed/,
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
});

test("GitHub client distinguishes absence from API failure and never edits", () => {
  const commands = [];
  const responses = [
    { status: 1, stdout: "", stderr: "gh: Not Found (HTTP 404)" },
    { status: 1, stdout: "", stderr: "gh: service unavailable (HTTP 503)" },
    { status: 0, stdout: "", stderr: "" },
  ];
  const runner = (_command, arguments_) => {
    commands.push(arguments_);
    return responses.shift();
  };
  const client = new GhReleaseClient(request.repository, runner);
  assert.equal(client.lookup(request.tag), null);
  assert.throws(() => client.lookup(request.tag), /503/);
  assert.equal(client.create({ ...request, version: "1.2.3" }), true);
  const create = commands[2];
  assert.deepEqual(create.slice(0, 3), ["release", "create", request.tag]);
  assert.ok(create.includes("--verify-tag"));
  assert.ok(create.includes("--latest=false"));
  assert.ok(!create.includes("--draft"));
  assert.ok(!commands.flat().includes("edit"));
  assert.ok(!commands.flat().includes("--clobber"));
});

test("CLI validates once and creates an absent exact release", () => {
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
      ],
      {
        encoding: "utf8",
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { ok: true, created: true });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
