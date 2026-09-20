import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import test from "node:test";

import {
  publishAppleAndroidRelease,
  validateAppleAndroidPublication,
} from "./publish-apple-android-release.mjs";

const COMMIT = "a".repeat(40);
const RELEASE_COMMIT = "9".repeat(40);
const CANDIDATE = {
  candidateCommit: COMMIT,
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

function sha(value) {
  return createHash("sha256").update(value).digest("hex");
}

function androidUniversal() {
  return {
    manifestSha256: "1".repeat(64),
    schemaVersion: 1,
    target: "android-universal",
    library: "libopenburnbar_domain_ffi.so",
    candidateAar: {
      fileName: "openburnbar-domain-core.aar",
      sha256: "2".repeat(64),
    },
    abis: [
      {
        abi: "arm64-v8a",
        path: "base/lib/arm64-v8a/libopenburnbar_domain_ffi.so",
        sha256: "3".repeat(64),
      },
      {
        abi: "x86_64",
        path: "base/lib/x86_64/libopenburnbar_domain_ffi.so",
        sha256: "4".repeat(64),
      },
    ],
  };
}

function predicate(consumer, domain, artifact, version) {
  const contract = {
    apple: ["macos-dmg", "macos-arm64"],
    android: ["android-aab", "android-universal"],
  }[consumer];
  return {
    schemaVersion: 2,
    predicateType:
      "https://openburnbar.dev/attestations/domain-core-release-artifact/v2",
    consumer,
    domain,
    artifactKind: contract[0],
    target: contract[1],
    ...(consumer === "android" ? { androidUniversal: androidUniversal() } : {}),
    candidate: CANDIDATE,
    sourceRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/domain-core.yml",
      runId: 101,
      runAttempt: 2,
      event: "push",
      ref: "refs/heads/main",
      headSha: COMMIT,
    },
    promotionProof: {
      signerWorkflow: ".github/workflows/domain-core-promotion-proof.yml",
      predicateType: "https://slsa.dev/provenance/v1",
      signerRun: { runId: 202, runAttempt: 3 },
      attestationSubject: {
        fileName: "domain-core-candidate-bundle.json",
        sha256: "c".repeat(64),
      },
      attestationBundleSha256: "d".repeat(64),
    },
    rollbackArtifact: {
      fileName: "domain-core-legacy-rollback.json",
      sha256: "e".repeat(64),
      candidate: CANDIDATE,
      activation: {
        candidateCommit: COMMIT,
        activationCommit: RELEASE_COMMIT,
        coreVersion: CANDIDATE.coreVersion,
        abiVersion: CANDIDATE.abiVersion,
        sourceSha256: CANDIDATE.sourceSha256,
        changedPathsSha256: "0".repeat(64),
      },
    },
    activation: {
      candidateCommit: COMMIT,
      activationCommit: RELEASE_COMMIT,
      coreVersion: CANDIDATE.coreVersion,
      abiVersion: CANDIDATE.abiVersion,
      sourceSha256: CANDIDATE.sourceSha256,
      changedPathsSha256: "0".repeat(64),
    },
    publicProfile: {
      profile: "public-production",
      domain,
      mode: "rust",
      sha256: "f".repeat(64),
    },
    artifact: {
      fileName: basename(artifact),
      sha256: sha(readFileSync(artifact)),
    },
    release: {
      version,
      tag: `v${version}`,
      commit: RELEASE_COMMIT,
      publicProfileSha256: "f".repeat(64),
    },
  };
}

function fixture({ prerelease = false, version: requestedVersion } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "apple-android-release-test-"));
  const version =
    requestedVersion ?? (prerelease ? "1.2.3-beta.1" : "1.2.3");
  const tag = `v${version}`;
  const notesPath = join(directory, "notes.md");
  const dmg = join(directory, `OpenBurnBar-${version}-macOS.dmg`);
  const aab = join(directory, `OpenBurnBar-${version}-Android.aab`);
  const zip = join(directory, `OpenBurnBar-${version}-macOS.zip`);
  const applePredicatePath = join(directory, "apple.predicate.json");
  const androidPredicatePath = join(directory, "android.predicate.json");
  const appleBundle = join(
    directory,
    `OpenBurnBar-${version}-apple-quota-domain-core.sigstore.json`,
  );
  const androidBundle = join(
    directory,
    `OpenBurnBar-${version}-android-cloudVault-domain-core.sigstore.json`,
  );
  writeFileSync(notesPath, `Release ${version}\n`);
  writeFileSync(dmg, "signed-dmg");
  writeFileSync(aab, "signed-aab");
  writeFileSync(zip, "signed-zip");
  writeFileSync(appleBundle, "apple-attestation");
  writeFileSync(androidBundle, "android-attestation");
  const applePredicate = predicate("apple", "quota", dmg, version);
  const androidPredicate = predicate("android", "cloudVault", aab, version);
  writeFileSync(applePredicatePath, JSON.stringify(applePredicate));
  writeFileSync(androidPredicatePath, JSON.stringify(androidPredicate));
  const native = (
    consumer,
    artifactPath,
    bundlePath,
    predicatePath,
    domain,
  ) => ({
    schemaVersion: 2,
    repository: "Imagine-That-Ai/BurnBar",
    tag,
    commit: RELEASE_COMMIT,
    consumer,
    signerWorkflow: ".github/workflows/release.yml",
    releaseState: "draft-then-publish",
    nativeArtifactOnly: false,
    artifactPath,
    bundles: [
      {
        domain,
        assetName: basename(bundlePath),
        bundlePath,
        predicatePath,
      },
    ],
  });
  const raw = {
    schemaVersion: 1,
    repository: "Imagine-That-Ai/BurnBar",
    tag,
    commit: RELEASE_COMMIT,
    title: `OpenBurnBar ${version}`,
    notesPath,
    prerelease,
    promote: false,
    apple: native("apple", dmg, appleBundle, applePredicatePath, "quota"),
    android: native(
      "android",
      aab,
      androidBundle,
      androidPredicatePath,
      "cloudVault",
    ),
    assets: [{ path: zip }],
  };
  return {
    directory,
    raw,
    publication: validateAppleAndroidPublication(raw),
    applePredicate,
    androidPredicate,
    names: [
      basename(dmg),
      basename(aab),
      basename(appleBundle),
      basename(androidBundle),
      basename(zip),
    ],
  };
}

class FakeClient {
  constructor(files, state = "draft") {
    this.files = files;
    this.state = state;
    this.latest = false;
    this.assets = new Map();
    this.assetIDs = new Map();
    this.nextAssetID = 1000;
    this.calls = [];
    this.uploadHook = undefined;
    this.downloadHook = undefined;
    this.lookupHook = undefined;
    this.latestLookupHook = undefined;
    this.editHook = undefined;
    this.tagLookupFails = false;
  }

  asset(name, bytes) {
    if (!this.assetIDs.has(name)) {
      this.assetIDs.set(name, this.nextAssetID);
      this.nextAssetID += 1;
    }
    return {
      id: this.assetIDs.get(name),
      name,
      size: bytes.length,
      digest: `sha256:${sha(bytes)}`,
    };
  }

  release() {
    return {
      id: 9001,
      tag_name: this.files.raw.tag,
      target_commitish: RELEASE_COMMIT,
      name: this.files.raw.title,
      body: readFileSync(this.files.raw.notesPath, "utf8"),
      draft: this.state === "draft",
      prerelease: this.files.raw.prerelease,
      assets: [...this.assets.entries()].map(([name, bytes]) =>
        this.asset(name, bytes),
      ),
    };
  }

  run(args, { allowFailure = false } = {}) {
    this.calls.push([...args]);
    if (args[0] === "attestation") {
      const bundle = basename(args[args.indexOf("--bundle") + 1]);
      const predicate = bundle.includes("apple")
        ? this.files.applePredicate
        : this.files.androidPredicate;
      return {
        status: 0,
        stdout: JSON.stringify([
          { verificationResult: { statement: { predicate } } },
        ]),
        stderr: "",
      };
    }
    if (args[0] === "api" && args[1].includes("/commits/")) {
      return {
        status: 0,
        stdout: JSON.stringify({ sha: RELEASE_COMMIT }),
        stderr: "",
      };
    }
    if (args[0] === "api" && args[1].endsWith("/releases/latest")) {
      if (this.latestLookupHook) {
        const result = this.latestLookupHook(this);
        if (result) return result;
      }
      if (this.state !== "published" || !this.latest) {
        return { status: 1, stdout: "", stderr: "HTTP 404" };
      }
      return { status: 0, stdout: JSON.stringify(this.release()), stderr: "" };
    }
    if (args[0] === "api" && args[1].includes("/releases/tags/")) {
      if (this.lookupHook) this.lookupHook(this);
      if (this.state === "absent" || this.tagLookupFails) {
        return { status: 1, stdout: "", stderr: "HTTP 404" };
      }
      return { status: 0, stdout: JSON.stringify(this.release()), stderr: "" };
    }
    if (args[0] === "api" && args[1].includes("/releases?")) {
      if (this.state === "absent") {
        return { status: 0, stdout: "[]", stderr: "" };
      }
      return { status: 0, stdout: JSON.stringify([this.release()]), stderr: "" };
    }
    if (args[0] === "release" && args[1] === "create") {
      if (this.state !== "absent")
        return { status: 1, stdout: "", stderr: "exists" };
      this.state = "draft";
      return { status: 0, stdout: "", stderr: "" };
    }
    if (args[0] === "release" && args[1] === "upload") {
      const path = args[3];
      const name = basename(path);
      if (this.uploadHook) {
        const value = this.uploadHook(name, path, this);
        if (value) return value;
      }
      if (this.assets.has(name))
        return { status: 1, stdout: "", stderr: "exists" };
      this.assets.set(name, readFileSync(path));
      return { status: 0, stdout: "", stderr: "" };
    }
    if (args[0] === "release" && args[1] === "download") {
      const name = args[args.indexOf("--pattern") + 1];
      const directory = args[args.indexOf("--dir") + 1];
      let bytes = this.assets.get(name);
      if (!bytes) throw new Error(`missing ${name}`);
      if (this.downloadHook) bytes = this.downloadHook(name, bytes) ?? bytes;
      mkdirSync(directory, { recursive: true });
      writeFileSync(join(directory, name), bytes);
      return { status: 0, stdout: "", stderr: "" };
    }
    if (args[0] === "release" && args[1] === "edit") {
      if (this.editHook) return this.editHook(args, this);
      this.state = args.includes("--draft=true") ? "draft" : "published";
      if (args.includes("--latest")) this.latest = true;
      if (args.includes("--latest=false")) this.latest = false;
      return { status: 0, stdout: "", stderr: "" };
    }
    if (allowFailure) return { status: 1, stdout: "", stderr: "unsupported" };
    throw new Error(`unsupported call: ${args.join(" ")}`);
  }
}

function mutations(client) {
  return client.calls.filter(
    (args) =>
      args[0] === "release" &&
      new Set(["create", "upload", "edit", "delete"]).has(args[1]),
  );
}

test("Android publication rejects missing or malformed universal ABI identity", () => {
  const files = fixture();
  try {
    const predicatePath = files.raw.android.bundles[0].predicatePath;
    const missing = structuredClone(files.androidPredicate);
    delete missing.androidUniversal;
    writeFileSync(predicatePath, JSON.stringify(missing));
    assert.throws(
      () => validateAppleAndroidPublication(files.raw),
      /must contain exactly.*androidUniversal/u,
    );

    const tampered = structuredClone(files.androidPredicate);
    tampered.androidUniversal.abis[1].path =
      "base/lib/x86/libopenburnbar_domain_ffi.so";
    writeFileSync(predicatePath, JSON.stringify(tampered));
    assert.throws(
      () => validateAppleAndroidPublication(files.raw),
      /invalid x86_64 identity/u,
    );
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
});

function seedExact(client, publication) {
  for (const asset of publication.assets) {
    client.assets.set(asset.name, readFileSync(asset.path));
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

test("stages the complete stable set create-only and publishes exactly once last", () => {
  withFixture({}, (files) => {
    const client = new FakeClient(files, "absent");
    const result = publishAppleAndroidRelease(files.publication, { client });
    assert.equal(result.published, true);
    assert.deepEqual(new Set(result.uploaded), new Set(files.names));
    assert.deepEqual(
      mutations(client).map((args) => args[1]),
      ["create", ...files.names.map(() => "upload"), "edit"],
    );
    const edit = mutations(client).at(-1);
    assert.equal(edit.includes("--draft=false"), true);
    assert.equal(edit.includes("--prerelease=false"), true);
    assert.equal(edit.includes("--latest=false"), true);
    assert.equal(edit.includes("--latest"), false);
    assert.equal(
      client.calls.some((args) => args.includes("--clobber")),
      false,
    );
    assert.equal(client.state, "published");
  });
});

test("draft publication falls back to the release list when tag lookup returns 404", () => {
  withFixture({}, (files) => {
    const client = new FakeClient(files, "draft");
    client.tagLookupFails = true;
    const result = publishAppleAndroidRelease(files.publication, { client });
    assert.equal(result.published, true);
    assert.equal(
      client.calls.some(
        (args) => args[0] === "api" && args[1].includes("/releases?"),
      ),
      true,
    );
    assert.equal(
      mutations(client).some((args) => args[1] === "create"),
      false,
    );
  });
});

test("prerelease creation and publication use explicit non-latest state", () => {
  withFixture({ prerelease: true }, (files) => {
    const client = new FakeClient(files, "absent");
    publishAppleAndroidRelease(files.publication, { client });
    const create = mutations(client).find((args) => args[1] === "create");
    const edit = mutations(client).find((args) => args[1] === "edit");
    assert.equal(create.includes("--prerelease"), true);
    assert.equal(create.includes("--prerelease=false"), false);
    assert.equal(edit.includes("--prerelease=true"), true);
    assert.equal(edit.includes("--latest=false"), true);
  });
});

test("stable build metadata containing a hyphen is not a prerelease", () => {
  withFixture({ version: "1.2.3+linux-x64" }, (files) => {
    assert.equal(files.publication.prerelease, false);
    files.publication.promote = true;
    const client = new FakeClient(files, "absent");
    publishAppleAndroidRelease(files.publication, { client });
    const create = mutations(client).find((args) => args[1] === "create");
    const edit = mutations(client).find((args) => args[1] === "edit");
    assert.equal(create.includes("--prerelease"), false);
    assert.equal(edit.includes("--prerelease=false"), true);
    assert.equal(edit.includes("--latest"), true);
  });
});

test("complete published retry is strictly read-only", () => {
  withFixture({}, (files) => {
    const client = new FakeClient(files, "published");
    seedExact(client, files.publication);
    assert.deepEqual(
      publishAppleAndroidRelease(files.publication, { client }),
      {
        published: false,
        uploaded: [],
        readOnly: true,
      },
    );
    assert.deepEqual(mutations(client), []);
  });
});

test("published promotion audits every exact asset before the sole latest mutation", () => {
  withFixture({}, (files) => {
    files.publication.promote = true;
    const client = new FakeClient(files, "published");
    seedExact(client, files.publication);
    assert.deepEqual(
      publishAppleAndroidRelease(files.publication, { client }),
      {
        published: false,
        uploaded: [],
        readOnly: false,
        promoted: true,
        promotionApplied: true,
      },
    );

    const editIndex = client.calls.findIndex(
      (args) => args[0] === "release" && args[1] === "edit",
    );
    assert.notEqual(editIndex, -1);
    assert.deepEqual(
      new Set(
        client.calls
          .slice(0, editIndex)
          .filter(
            (args) => args[0] === "release" && args[1] === "download",
          )
          .map((args) => args[args.indexOf("--pattern") + 1]),
      ),
      new Set(files.names),
    );
    assert.deepEqual(mutations(client), [
      [
        "release",
        "edit",
        files.raw.tag,
        "--repo",
        files.raw.repository,
        "--latest",
      ],
    ]);
    assert.equal(
      client.calls.some(
        (args) => args[0] === "api" && args[1].endsWith("/releases/latest"),
      ),
      true,
    );
  });
});

test("published promotion is idempotent when the exact release is already latest", () => {
  withFixture({}, (files) => {
    files.publication.promote = true;
    const client = new FakeClient(files, "published");
    seedExact(client, files.publication);
    client.latest = true;
    client.editHook = () => ({
      status: 1,
      stdout: "",
      stderr: "concurrent promotion",
    });
    const result = publishAppleAndroidRelease(files.publication, { client });
    assert.equal(result.promoted, true);
    assert.equal(result.promotionApplied, false);
  });
});

test("published promotion detects release substitution after the latest mutation", () => {
  withFixture({}, (files) => {
    files.publication.promote = true;
    const client = new FakeClient(files, "published");
    seedExact(client, files.publication);
    client.editHook = (_args, instance) => {
      instance.latest = true;
      instance.assets.set(files.names.at(-1), Buffer.from("substituted"));
      return { status: 0, stdout: "", stderr: "" };
    };
    assert.throws(
      () => publishAppleAndroidRelease(files.publication, { client }),
      /latest release verification changed the audited release or asset identity/u,
    );
    assert.equal(mutations(client).length, 1);
  });
});

test("published missing DMG or different general bytes blocks promotion with zero mutation", () => {
  withFixture({}, (files) => {
    for (const mode of ["missing-dmg", "different-zip"]) {
      files.publication.promote = true;
      const client = new FakeClient(files, "published");
      seedExact(client, files.publication);
      if (mode === "missing-dmg") client.assets.delete(files.names[0]);
      else client.assets.set(files.names.at(-1), Buffer.from("substituted"));
      assert.throws(
        () => publishAppleAndroidRelease(files.publication, { client }),
        mode === "missing-dmg"
          ? /asset set mismatch/
          : /differs from exact local bytes/,
      );
      assert.deepEqual(mutations(client), []);
    }
  });
});

test("draft retry adopts a valid existing evidence encoding and fills only missing assets", () => {
  withFixture({}, (files) => {
    const client = new FakeClient(files, "draft");
    const evidence = files.publication.assets.find((asset) => asset.evidence);
    client.assets.set(evidence.name, Buffer.from("alternate-valid-encoding"));
    const result = publishAppleAndroidRelease(files.publication, { client });
    assert.equal(result.uploaded.includes(evidence.name), false);
    assert.equal(client.state, "published");
  });
});

test("unexpected draft assets and final byte tampering keep the release draft", () => {
  withFixture({}, (files) => {
    const extra = new FakeClient(files, "draft");
    extra.assets.set("attacker.bin", Buffer.from("x"));
    assert.throws(
      () => publishAppleAndroidRelease(files.publication, { client: extra }),
      /unexpected=attacker.bin/,
    );
    assert.deepEqual(mutations(extra), []);

    const tampered = new FakeClient(files, "draft");
    tampered.downloadHook = (name, bytes) =>
      name === files.names.at(-1) ? Buffer.from("tampered") : bytes;
    assert.throws(
      () => publishAppleAndroidRelease(files.publication, { client: tampered }),
      /differs from exact local bytes/,
    );
    assert.equal(tampered.state, "draft");
    assert.equal(
      mutations(tampered).some((args) => args[1] === "edit"),
      false,
    );
  });
});

test("a concurrent exact upload is recovered but a substituted collision fails", () => {
  withFixture({}, (files) => {
    for (const exact of [true, false]) {
      const client = new FakeClient(files, "draft");
      client.uploadHook = (name, path, instance) => {
        instance.uploadHook = undefined;
        instance.assets.set(
          name,
          exact ? readFileSync(path) : Buffer.from("substituted"),
        );
        return { status: 1, stdout: "", stderr: "collision" };
      };
      if (exact) {
        publishAppleAndroidRelease(files.publication, { client });
        assert.equal(client.state, "published");
      } else {
        assert.throws(
          () => publishAppleAndroidRelease(files.publication, { client }),
          /differs from exact local bytes/,
        );
        assert.equal(client.state, "draft");
      }
    }
  });
});

test("state and tag TOCTOU substitutions prevent further publication", () => {
  withFixture({}, (files) => {
    const stateRace = new FakeClient(files, "draft");
    let lookups = 0;
    stateRace.lookupHook = (instance) => {
      lookups += 1;
      if (lookups === 3) instance.state = "published";
    };
    assert.throws(
      () =>
        publishAppleAndroidRelease(files.publication, { client: stateRace }),
      /left draft state/,
    );
    assert.equal(
      mutations(stateRace).some((args) => args[1] === "edit"),
      false,
    );

    const movedTag = new FakeClient(files, "draft");
    const original = movedTag.run.bind(movedTag);
    let tagLookups = 0;
    movedTag.run = (args, options) => {
      if (args[0] === "api" && args[1].includes("/commits/")) {
        tagLookups += 1;
        if (tagLookups === 3) {
          movedTag.calls.push([...args]);
          return {
            status: 0,
            stdout: JSON.stringify({ sha: "8".repeat(40) }),
            stderr: "",
          };
        }
      }
      return original(args, options);
    };
    assert.throws(
      () => publishAppleAndroidRelease(files.publication, { client: movedTag }),
      /does not resolve/,
    );
    assert.equal(
      mutations(movedTag).some((args) => args[1] === "edit"),
      false,
    );
  });
});

test("failed final edit accepts only a complete exact concurrent publication", () => {
  withFixture({}, (files) => {
    const concurrent = new FakeClient(files, "draft");
    concurrent.editHook = (_args, instance) => {
      instance.state = "published";
      return { status: 1, stdout: "", stderr: "concurrent" };
    };
    const result = publishAppleAndroidRelease(files.publication, {
      client: concurrent,
    });
    assert.equal(result.published, false);
    assert.equal(
      mutations(concurrent).filter((args) => args[1] === "edit").length,
      1,
    );
  });
});

test("asset interference during final edit fails audit and redrafts", () => {
  withFixture({}, (files) => {
    const client = new FakeClient(files, "draft");
    client.editHook = (args, instance) => {
      if (args.includes("--draft=true")) {
        instance.state = "draft";
        return { status: 0, stdout: "", stderr: "" };
      }
      instance.state = "published";
      instance.assets.set("unexpected-admin-asset.bin", Buffer.from("x"));
      return { status: 0, stdout: "", stderr: "" };
    };
    assert.throws(
      () => publishAppleAndroidRelease(files.publication, { client }),
      /unexpected=unexpected-admin-asset\.bin/u,
    );
    assert.equal(client.state, "draft");
    const edits = mutations(client).filter((args) => args[1] === "edit");
    assert.equal(edits.length, 2);
    assert.equal(edits[0].includes("--draft=false"), true);
    assert.equal(edits[1].includes("--draft=true"), true);
  });
});
