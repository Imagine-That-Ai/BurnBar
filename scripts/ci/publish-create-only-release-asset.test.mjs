import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  GhReleaseClient,
  preflightAsset,
  publishAsset,
  validateRequest,
} from "./publish-create-only-release-asset.mjs";

const COMMIT = "a".repeat(40);
const SCRIPT = fileURLToPath(
  new URL("./publish-create-only-release-asset.mjs", import.meta.url),
);

function fixture({ prerelease = true } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "create-only-asset-test-"));
  const version = prerelease ? "1.2.3-beta.1" : "1.2.3";
  const artifact = join(directory, `OpenBurnBar-${version}-macOS.dmg`);
  writeFileSync(artifact, "signed-dmg-bytes");
  return {
    directory,
    request: {
      phase: "preflight",
      repository: "Imagine-That-Ai/BurnBar",
      tag: `v${version}`,
      commit: COMMIT,
      artifact,
      expectedPrerelease: prerelease,
    },
  };
}

class FakeClient {
  constructor(request, { release = true } = {}) {
    this.request = request;
    this.releaseExists = release;
    this.assets = new Map();
    this.mutations = [];
    this.uploadHook = undefined;
    this.downloadHook = undefined;
    this.releaseOverride = {};
  }

  resolveTagCommit() {
    return this.request.commit;
  }

  lookup() {
    if (!this.releaseExists) return null;
    return {
      tag_name: this.request.tag,
      target_commitish: this.request.commit,
      draft: false,
      prerelease: this.request.expectedPrerelease,
      assets: [...this.assets.keys()].map((name) => ({ name })),
      ...this.releaseOverride,
    };
  }

  download(_tag, name, directory) {
    const contents = this.assets.get(name);
    if (contents === undefined) throw new Error(`missing asset ${name}`);
    const path = join(directory, name);
    const value = this.downloadHook?.(name, contents) ?? contents;
    mkdirSync(directory, { recursive: true });
    writeFileSync(path, value);
    return path;
  }

  upload(_tag, path) {
    this.mutations.push(["upload", basename(path)]);
    const hooked = this.uploadHook?.(path, this);
    if (hooked) return hooked;
    const name = basename(path);
    if (this.assets.has(name)) {
      return { status: 1, stdout: "", stderr: "already exists" };
    }
    this.assets.set(name, readFileSync(path));
    return { status: 0, stdout: "", stderr: "" };
  }
}

function withFixture(options, callback) {
  const files = fixture(options);
  try {
    callback(files);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
}

test("preflight accepts an absent release and performs zero mutations", () => {
  withFixture({}, ({ request }) => {
    const client = new FakeClient(request, { release: false });
    assert.deepEqual(preflightAsset(request, { client }), {
      releaseExists: false,
      assetExists: false,
    });
    assert.deepEqual(client.mutations, []);
  });
});

test("preflight rejects non-identical existing bytes with zero mutations", () => {
  withFixture({}, ({ request }) => {
    const client = new FakeClient(request);
    client.assets.set(basename(request.artifact), Buffer.from("other-dmg"));
    assert.throws(
      () => preflightAsset(request, { client }),
      /refusing to replace non-identical/u,
    );
    assert.deepEqual(client.mutations, []);
  });
});

test("publish rejects non-identical existing bytes with zero mutations", () => {
  withFixture({}, ({ request }) => {
    const client = new FakeClient(request);
    client.assets.set(basename(request.artifact), Buffer.from("other-dmg"));
    assert.throws(
      () => publishAsset(request, { client }),
      /refusing to replace non-identical/u,
    );
    assert.deepEqual(client.mutations, []);
  });
});

test("publish uploads a missing asset create-only and verifies final bytes", () => {
  for (const draft of [true, false]) {
    withFixture({}, ({ request }) => {
      const client = new FakeClient(request);
      client.releaseOverride = { draft };
      assert.deepEqual(publishAsset(request, { client }), { uploaded: true });
      assert.deepEqual(client.mutations, [
        ["upload", basename(request.artifact)],
      ]);
      assert.deepEqual(
        client.assets.get(basename(request.artifact)),
        readFileSync(request.artifact),
      );
    });
  }
});

test("publish recovers an upload collision only when concurrent bytes are exact", () => {
  for (const exact of [true, false]) {
    withFixture({}, ({ request }) => {
      const client = new FakeClient(request);
      client.uploadHook = (path, fake) => {
        fake.assets.set(
          basename(path),
          exact ? readFileSync(path) : Buffer.from("attacker-bytes"),
        );
        return { status: 1, stdout: "", stderr: "already exists" };
      };
      if (exact) {
        assert.deepEqual(publishAsset(request, { client }), {
          uploaded: false,
        });
      } else {
        assert.throws(
          () => publishAsset(request, { client }),
          /concurrent immutable release asset differs/u,
        );
      }
      assert.equal(client.mutations.length, 1);
    });
  }
});

test("final re-download mismatch fails after a successful upload", () => {
  withFixture({}, ({ request }) => {
    const client = new FakeClient(request);
    let downloads = 0;
    client.downloadHook = (_name, contents) => {
      downloads += 1;
      return downloads === 1 ? Buffer.from("post-upload-tamper") : contents;
    };
    assert.throws(
      () => publishAsset(request, { client }),
      /published release asset differs/u,
    );
    assert.equal(client.mutations.length, 1);
  });
});

test("release and tag identity substitutions fail before upload", () => {
  withFixture({}, ({ request }) => {
    for (const releaseOverride of [
      { tag_name: "v1.2.3-beta.2" },
      { target_commitish: "b".repeat(40) },
      { draft: "true" },
      { prerelease: false },
    ]) {
      const client = new FakeClient(request);
      client.releaseOverride = releaseOverride;
      assert.throws(() => publishAsset(request, { client }), /release must/u);
      assert.deepEqual(client.mutations, []);
    }
    const movedTag = new FakeClient(request);
    movedTag.resolveTagCommit = () => "b".repeat(40);
    assert.throws(
      () => publishAsset(request, { client: movedTag }),
      /tag does not resolve/u,
    );
    assert.deepEqual(movedTag.mutations, []);
  });
});

test("request validation rejects extra fields, bad names, tag disagreement, and symlinks", () => {
  withFixture({}, ({ directory, request }) => {
    assert.throws(
      () => validateRequest({ ...request, extra: true }),
      /exactly/u,
    );
    assert.throws(
      () => validateRequest({ ...request, repository: "owner/fork" }),
      /repository/u,
    );
    assert.throws(
      () => validateRequest({ ...request, commit: "A".repeat(40) }),
      /commit/u,
    );
    assert.throws(
      () => validateRequest({ ...request, expectedPrerelease: false }),
      /agree/u,
    );
    const wrongName = join(directory, "release.dmg");
    writeFileSync(wrongName, "signed-dmg-bytes");
    assert.throws(
      () => validateRequest({ ...request, artifact: wrongName }),
      /must be named/u,
    );
    assert.throws(
      () => validateRequest({ ...request, artifact: basename(wrongName) }),
      /absolute path/u,
    );
    const link = join(directory, basename(request.artifact));
    const target = join(directory, "target.dmg");
    writeFileSync(target, "signed-dmg-bytes");
    rmSync(link);
    symlinkSync(target, link);
    assert.throws(
      () => validateRequest({ ...request, artifact: link }),
      /not a symlink/u,
    );
  });
});

test("a hyphen in build metadata does not imply prerelease state", () => {
  withFixture({ prerelease: false }, ({ directory, request }) => {
    const artifact = join(directory, "OpenBurnBar-1.2.3+build-x-macOS.dmg");
    writeFileSync(artifact, "signed-dmg-bytes");
    assert.equal(
      validateRequest({
        ...request,
        tag: "v1.2.3+build-x",
        artifact,
      }).expectedPrerelease,
      false,
    );
  });
});

test("GitHub upload command has no clobber capability", () => {
  const commands = [];
  const client = new GhReleaseClient(
    "Imagine-That-Ai/BurnBar",
    (_command, args) => {
      commands.push(args);
      return { status: 0, stdout: "", stderr: "" };
    },
  );
  assert.equal(client.upload("v1.2.3", "/tmp/asset.dmg").status, 0);
  assert.deepEqual(commands, [
    [
      "release",
      "upload",
      "v1.2.3",
      "/tmp/asset.dmg",
      "--repo",
      "Imagine-That-Ai/BurnBar",
    ],
  ]);
  assert.equal(commands.flat().includes("--clobber"), false);
});

test("CLI preflight validates an absent exact release without mutation", () => {
  withFixture({}, ({ directory, request }) => {
    const bin = join(directory, "bin");
    mkdirSync(bin);
    const gh = join(bin, "gh");
    writeFileSync(
      gh,
      `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === "api" && args[1].includes("/commits/")) {
  process.stdout.write(JSON.stringify({ sha: "${COMMIT}" }));
  process.exit(0);
}
if (args[0] === "api" && args[1].includes("/releases/tags/")) {
  process.stderr.write("gh: Not Found (HTTP 404)\\n");
  process.exit(1);
}
process.stderr.write("unexpected mutation: " + args.join(" ") + "\\n");
process.exit(9);
`,
    );
    chmodSync(gh, 0o755);
    const result = spawnSync(
      process.execPath,
      [
        SCRIPT,
        "--phase",
        "preflight",
        "--repository",
        request.repository,
        "--tag",
        request.tag,
        "--commit",
        request.commit,
        "--artifact",
        request.artifact,
        "--expected-prerelease",
        "true",
      ],
      {
        encoding: "utf8",
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      ok: true,
      releaseExists: false,
      assetExists: false,
    });
  });
});
