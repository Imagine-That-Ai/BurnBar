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
  constructor({ lookups = [null], create = true } = {}) {
    this.lookupValues = [...lookups];
    this.lastLookup = this.lookupValues.at(-1) ?? null;
    this.createResult = create;
    this.creates = 0;
    this.lookups = 0;
  }

  lookup() {
    this.lookups += 1;
    return this.lookupValues.length > 0
      ? this.lookupValues.shift()
      : this.lastLookup;
  }

  resolveTagCommit() {
    return request.commit;
  }

  createDraft(value) {
    this.creates += 1;
    assert.equal(value.version, "1.2.3");
    return this.createResult;
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

test("the preparation helper cannot publish a Windows release", () => {
  assert.throws(
    () => manageRelease({ ...request, phase: "publish" }, new FakeClient()),
    /phase must be prepare/u,
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

test("rejects a release tag moved away from the requested candidate", () => {
  const client = new FakeClient();
  client.resolveTagCommit = () => "b".repeat(40);
  assert.throws(
    () => manageRelease(request, client),
    /does not resolve to the requested candidate commit/u,
  );
  assert.equal(client.creates, 0);
});

test("GitHub client distinguishes absence and can only create a draft", () => {
  const commands = [];
  const responses = [
    { status: 0, stdout: `${request.commit}\n`, stderr: "" },
    { status: 1, stdout: "", stderr: "gh: Not Found (HTTP 404)" },
    { status: 1, stdout: "", stderr: "gh: service unavailable (HTTP 503)" },
    { status: 0, stdout: "", stderr: "" },
  ];
  const runner = (_command, arguments_) => {
    commands.push(arguments_);
    return responses.shift();
  };
  const client = new GhReleaseClient(request.repository, runner);
  assert.equal(client.resolveTagCommit(request.tag), request.commit);
  assert.equal(client.lookup(request.tag), null);
  assert.throws(() => client.lookup(request.tag), /503/);
  assert.equal(client.createDraft({ ...request, version: "1.2.3" }), true);
  assert.deepEqual(commands[0].slice(0, 2), [
    "api",
    `repos/${request.repository}/commits/${request.tag}`,
  ]);
  const create = commands[3];
  assert.deepEqual(create.slice(0, 3), ["release", "create", request.tag]);
  assert.ok(create.includes("--verify-tag"));
  assert.ok(create.includes("--latest=false"));
  assert.ok(create.includes("--draft"));
  assert.equal(commands.length, 4);
  assert.equal(
    commands.some((command) => command[1] === "edit"),
    false,
  );
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
  if (args[1].includes("/commits/")) {
    process.stdout.write("${request.commit}\\n");
    process.exit(0);
  }
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
