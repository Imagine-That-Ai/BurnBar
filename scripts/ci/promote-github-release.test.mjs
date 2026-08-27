import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  auditExistingRelease,
  auditRollbackTargetRelease,
  expectedReleaseAssets,
  promoteAuditedRelease,
  promoteAuditedRollbackTarget,
  validateRollbackTargetReceipt,
  verifyDomainCoreBundles,
} from "./promote-github-release.mjs";

const REPOSITORY = "Imagine-That-Ai/BurnBar";
const VERSION = "1.2.3";
const TAG = `v${VERSION}`;
const COMMIT = "a".repeat(40);
const PUBLIC_PROFILE = "public-production";
const ROLLBACK_PROFILE = "public-production-rollback";

function hash(algorithm, value) {
  return createHash(algorithm).update(value).digest("hex");
}

function fixture(domainCoreProfile = PUBLIC_PROFILE) {
  const directory = mkdtempSync(join(tmpdir(), "release-promotion-test-"));
  const notesPath = join(directory, "notes.md");
  const assetDirectory = join(directory, "assets");
  const receiptPath = join(directory, "promotion-receipt.json");
  const notes = `Release ${VERSION}\n`;
  writeFileSync(notesPath, notes);

  const assets = new Map();
  const put = (name, contents) => {
    assets.set(name, Buffer.from(contents));
  };
  const dmg = `OpenBurnBar-${VERSION}-macOS.dmg`;
  const zip = `OpenBurnBar-${VERSION}-macOS.zip`;
  const android = `OpenBurnBar-${VERSION}-Android.aab`;
  const ios = `OpenBurnBar-${VERSION}-iOS.xcarchive.zip`;
  const source = `OpenBurnBar-${VERSION}-corresponding-source.tar.gz`;
  const rollback = `OpenBurnBar-${VERSION}-legacy-rollback.zip`;
  put(dmg, "signed-dmg");
  put(zip, "signed-zip");
  put(android, "signed-aab");
  if (domainCoreProfile === PUBLIC_PROFILE) put(ios, "signed-ios-archive");
  put(source, "corresponding-source");
  put(rollback, "rollback");
  put("appcast.xml", "");
  put("latest-macos.json", "");
  put(`sbom-v${VERSION}.spdx.json`, "{}\n");
  put(`openburnbar-v${VERSION}.vex.json`, "{}\n");
  put(`NOTICES-v${VERSION}.txt`, "notices\n");

  const sparkle = Buffer.alloc(64, 7).toString("base64");
  const updateBaseUrl =
    "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download";
  put(
    "latest-macos.json",
    `${JSON.stringify(
      {
        appcastUrl: `${updateBaseUrl}/appcast.xml`,
        build: "123",
        bundleId: "com.openburnbar.app",
        channel: "direct-download",
        commit: COMMIT,
        correspondingSource: source,
        createdAt: "2026-08-15T00:00:00Z",
        critical: false,
        dmg,
        downloadUrl: `${updateBaseUrl}/${dmg}`,
        length: assets.get(dmg).length,
        minimumSystemVersion: "14.0",
        releaseNotesUrl: `${updateBaseUrl}/release-metadata.json`,
        sha256: hash("sha256", assets.get(dmg)),
        sparkleEdSignature: sparkle,
        version: VERSION,
        zip,
      },
      null,
      2,
    )}\n`,
  );
  put(
    "appcast.xml",
    [
      `<link>${updateBaseUrl}/appcast.xml</link>`,
      "<item>",
      "<sparkle:version>123</sparkle:version>",
      `<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>`,
      "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>",
      `<sparkle:releaseNotesLink>${updateBaseUrl}/release-metadata.json</sparkle:releaseNotesLink>`,
      `<enclosure url="${updateBaseUrl}/${dmg}" length="${assets.get(dmg).length}" type="application/x-apple-diskimage" sparkle:edSignature="${sparkle}" />`,
      "</item>",
    ].join(""),
  );
  put(
    "release-metadata.json",
    `${JSON.stringify({
      appcast: "appcast.xml",
      build_timestamp: "2026-08-15T00:00:00Z",
      channel: "direct-download",
      commit: COMMIT,
      correspondingSource: source,
      latestMetadata: "latest-macos.json",
      runner_arch: "ARM64",
      runner_name: "fixture-runner",
      runner_os: "macOS",
      sparkleEdSignaturePresent: true,
      tag: TAG,
      updateBaseUrl,
      version: VERSION,
    })}\n`,
  );
  if (domainCoreProfile === PUBLIC_PROFILE) {
    put(
      `OpenBurnBar-${VERSION}-iOS-app-store-connect-receipt.json`,
      `${JSON.stringify({
        schemaVersion: 1,
        status: "processed",
        archiveSha256: hash("sha256", assets.get(ios)),
        release: { version: VERSION, tag: TAG, commit: COMMIT },
      })}\n`,
    );
  }
  put(
    `${source}.sha256`,
    `${hash("sha256", assets.get(source))}  /tmp/${source}\n`,
  );

  const checksummed = [
    dmg,
    zip,
    source,
    "appcast.xml",
    "latest-macos.json",
    rollback,
  ];
  put(
    `checksums-v${VERSION}.txt`,
    `${checksummed
      .flatMap((name) => [
        `${hash("sha256", assets.get(name))}  /tmp/${name}`,
        `${hash("sha512", assets.get(name))}  /tmp/${name}`,
      ])
      .join("\n")}\n`,
  );

  for (const name of expectedReleaseAssets(VERSION, domainCoreProfile)
    .required) {
    if (!assets.has(name)) put(name, `fixture:${name}`);
  }

  return {
    directory,
    notes,
    notesPath,
    assetDirectory,
    receiptPath,
    assets,
    domainCoreProfile,
  };
}

class FakeClient {
  constructor(files) {
    this.files = files;
    this.assets = new Map(files.assets);
    this.assetIDs = new Map(
      [...this.assets.keys()].sort().map((name, index) => [name, 1000 + index]),
    );
    this.latest = false;
    this.calls = [];
    this.downloadHook = undefined;
    this.editHook = undefined;
    this.latestOverride = undefined;
  }

  release() {
    return {
      id: 9001,
      tag_name: TAG,
      target_commitish: COMMIT,
      name: `OpenBurnBar ${VERSION}`,
      body: this.files.notes,
      draft: false,
      prerelease: false,
      assets: [...this.assets.entries()].map(([name, bytes]) => ({
        id: this.assetIDs.get(name) ?? 9999,
        name,
        size: bytes.length,
        digest: `sha256:${hash("sha256", bytes)}`,
      })),
    };
  }

  run(args, { allowFailure = false } = {}) {
    this.calls.push([...args]);
    if (args[0] === "api" && args[1].includes("/commits/")) {
      return {
        status: 0,
        stdout: JSON.stringify({ sha: COMMIT }),
        stderr: "",
      };
    }
    if (args[0] === "api" && args[1].endsWith("/releases/latest")) {
      if (this.latestOverride) return this.latestOverride(this);
      if (!this.latest) return { status: 1, stdout: "", stderr: "HTTP 404" };
      return { status: 0, stdout: JSON.stringify(this.release()), stderr: "" };
    }
    if (args[0] === "api" && args[1].includes("/releases/tags/")) {
      return { status: 0, stdout: JSON.stringify(this.release()), stderr: "" };
    }
    if (args[0] === "release" && args[1] === "download") {
      const name = args[args.indexOf("--pattern") + 1];
      const directory = args[args.indexOf("--dir") + 1];
      let bytes = this.assets.get(name);
      if (!bytes) throw new Error(`missing fake asset ${name}`);
      if (this.downloadHook) bytes = this.downloadHook(name, bytes) ?? bytes;
      writeFileSync(join(directory, name), bytes);
      return { status: 0, stdout: "", stderr: "" };
    }
    if (args[0] === "release" && args[1] === "edit") {
      if (this.editHook) return this.editHook(args, this);
      this.latest = args.includes("--latest");
      return { status: 0, stdout: "", stderr: "" };
    }
    if (allowFailure) return { status: 1, stdout: "", stderr: "unsupported" };
    throw new Error(`unsupported fake command: ${args.join(" ")}`);
  }
}

function withFixture(callback, domainCoreProfile = PUBLIC_PROFILE) {
  const files = fixture(domainCoreProfile);
  try {
    callback(files);
  } finally {
    rmSync(files.directory, { recursive: true, force: true });
  }
}

function audit(
  files,
  client,
  domainCoreVerifier = () => {},
  domainCoreProfile = files.domainCoreProfile,
) {
  return auditExistingRelease(
    {
      tag: TAG,
      commit: COMMIT,
      notesPath: files.notesPath,
      assetDirectory: files.assetDirectory,
      receiptPath: files.receiptPath,
      domainCoreProfile,
    },
    { client, domainCoreVerifier },
  );
}

function mutations(client) {
  return client.calls.filter(
    (args) => args[0] === "release" && args[1] === "edit",
  );
}

test("sidecar expectations use cosign's sanitised subject names", () => {
  // cosign writes bundles under a filesystem-safe subject, so a +repair build
  // ships `..._repair.N-macOS.dmg.sigstore.json`. verify-release-attestations.sh
  // re-derives the same form. Building these from the raw version made the audit
  // demand names no release can carry, and renaming the assets to match simply
  // broke the attestation verifier instead.
  const { required } = expectedReleaseAssets("1.0.40+repair.30", "public-production");
  for (const name of [
    "OpenBurnBar-1.0.40_repair.30-macOS.dmg.sigstore.json",
    "OpenBurnBar-1.0.40_repair.30-macOS.dmg.predicate.json",
    "OpenBurnBar-1.0.40_repair.30-legacy-rollback.zip.sigstore.json",
    "checksums-v1.0.40_repair.30.txt.sigstore.json",
    "sbom-v1.0.40_repair.30.spdx.json.sigstore.json",
    "openburnbar-v1.0.40_repair.30.vex.json.predicate.json",
  ]) {
    assert.equal(required.has(name), true, name);
  }
  // Only the cosign-produced sidecars are sanitised. The domain-core bundles
  // are `cp`'d to deterministic ${VERSION} names by the "Stage deterministic
  // attestation bundle names" step in release.yml, so they legitimately keep
  // the `+`. Pin both halves so neither is "fixed" into the other.
  for (const name of [...required]) {
    if (name.includes("domain-core")) continue;
    assert.equal(
      /\+.*\.(?:sigstore|predicate)\.json$/u.test(name),
      false,
      `cosign sidecar must be sanitised: ${name}`,
    );
  }
  assert.equal(
    required.has(
      "OpenBurnBar-1.0.40+repair.30-apple-quota-domain-core.sigstore.json",
    ),
    true,
    "staged domain-core bundles keep the raw version",
  );
  // A version with no build metadata is unchanged.
  const plain = expectedReleaseAssets("1.0.41", "public-production").required;
  assert.equal(plain.has("OpenBurnBar-1.0.41-macOS.dmg.sigstore.json"), true);
});

test("audits the exact complete remote release and writes an immutable receipt", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    let domainVerificationCalls = 0;
    const result = audit(files, client, () => {
      domainVerificationCalls += 1;
    });
    assert.equal(domainVerificationCalls, 1);
    assert.equal(result.release.identity.assets.length, files.assets.size);
    assert.equal(
      readFileSync(files.receiptPath, "utf8").includes(COMMIT),
      true,
    );
    assert.equal(mutations(client).length, 0);
    assert.deepEqual(
      new Set(
        client.calls
          .filter((args) => args[0] === "release" && args[1] === "download")
          .map((args) => args[args.indexOf("--pattern") + 1]),
      ),
      new Set(files.assets.keys()),
    );
  });
});

test("audits a legacy previous-good release into a rollback-only receipt", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    const assetDirectory = join(files.directory, "rollback-assets");
    const receiptPath = join(files.directory, "rollback-receipt.json");
    const result = auditRollbackTargetRelease(
      {
        tag: TAG,
        commit: COMMIT,
        assetDirectory,
        receiptPath,
      },
      { client },
    );
    const receipt = validateRollbackTargetReceipt(
      JSON.parse(readFileSync(receiptPath, "utf8")),
    );
    assert.equal(result.receiptPath, receiptPath);
    assert.equal(receipt.version, VERSION);
    assert.equal(receipt.commit, COMMIT);
    assert.deepEqual(
      receipt.identity.assets.map((asset) => asset.name),
      [
        `OpenBurnBar-${VERSION}-corresponding-source.tar.gz`,
        `OpenBurnBar-${VERSION}-corresponding-source.tar.gz.sha256`,
        `OpenBurnBar-${VERSION}-macOS.dmg`,
        `OpenBurnBar-${VERSION}-macOS.zip`,
        "appcast.xml",
        `checksums-v${VERSION}.txt`,
        "latest-macos.json",
        "release-metadata.json",
      ].sort((left, right) => left.localeCompare(right)),
    );
    assert.equal(mutations(client).length, 0);
  });
});

test("restores GitHub latest only from the unchanged audited rollback target", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    const assetDirectory = join(files.directory, "rollback-assets");
    const receiptPath = join(files.directory, "rollback-receipt.json");
    auditRollbackTargetRelease(
      {
        tag: TAG,
        commit: COMMIT,
        assetDirectory,
        receiptPath,
      },
      { client },
    );
    client.calls.length = 0;
    assert.deepEqual(promoteAuditedRollbackTarget(receiptPath, { client }), {
      promoted: true,
      promotionApplied: true,
    });
    assert.deepEqual(mutations(client), [
      ["release", "edit", TAG, "--repo", REPOSITORY, "--latest"],
    ]);
  });
});

test("rollback-target drift blocks GitHub latest restoration", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    const assetDirectory = join(files.directory, "rollback-assets");
    const receiptPath = join(files.directory, "rollback-receipt.json");
    auditRollbackTargetRelease(
      {
        tag: TAG,
        commit: COMMIT,
        assetDirectory,
        receiptPath,
      },
      { client },
    );
    client.calls.length = 0;
    client.assets.set(
      `OpenBurnBar-${VERSION}-macOS.dmg`,
      Buffer.from("changed-after-rollback-audit"),
    );
    assert.throws(
      () => promoteAuditedRollbackTarget(receiptPath, { client }),
      /rollback target changed after its audit/u,
    );
    assert.deepEqual(mutations(client), []);
  });
});

test("missing, unexpected, or substituted assets fail before any mutation", () => {
  for (const mode of ["missing", "unexpected", "substituted"]) {
    withFixture((files) => {
      const client = new FakeClient(files);
      if (mode === "missing") {
        client.assets.delete(`OpenBurnBar-${VERSION}-Android.aab`);
      } else if (mode === "unexpected") {
        client.assets.set("unexpected.bin", Buffer.from("unexpected"));
        client.assetIDs.set("unexpected.bin", 9998);
      } else {
        client.downloadHook = (name, bytes) =>
          name === `OpenBurnBar-${VERSION}-macOS.dmg`
            ? Buffer.from("substituted")
            : bytes;
      }
      assert.throws(
        () => audit(files, client),
        /asset set mismatch|does not match GitHub size and digest metadata/u,
      );
      assert.equal(mutations(client).length, 0);
    });
  }
});

test("domain-core verification failure prevents the promotion receipt", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    assert.throws(
      () =>
        audit(files, client, () => {
          throw new Error("invalid native attestation");
        }),
      /invalid native attestation/u,
    );
    assert.equal(mutations(client).length, 0);
  });
});

test("promotes only the unchanged audited release with one latest-only edit", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    audit(files, client);
    client.calls.length = 0;
    assert.deepEqual(promoteAuditedRelease(files.receiptPath, { client }), {
      promoted: true,
      promotionApplied: true,
    });
    assert.deepEqual(mutations(client), [
      ["release", "edit", TAG, "--repo", REPOSITORY, "--latest"],
    ]);
    assert.equal(
      client.calls.some(
        (args) => args[0] === "api" && args[1].endsWith("/releases/latest"),
      ),
      true,
    );
  });
});

test("an exact already-latest release is idempotent and read-only", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    audit(files, client);
    client.calls.length = 0;
    client.latest = true;
    assert.deepEqual(promoteAuditedRelease(files.receiptPath, { client }), {
      promoted: true,
      promotionApplied: false,
    });
    assert.deepEqual(mutations(client), []);
  });
});

test("release drift after audit blocks latest promotion", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    audit(files, client);
    client.calls.length = 0;
    client.assets.set(
      `OpenBurnBar-${VERSION}-Android.aab`,
      Buffer.from("replaced-after-audit"),
    );
    assert.throws(
      () => promoteAuditedRelease(files.receiptPath, { client }),
      /release changed after its promotion audit/u,
    );
    assert.deepEqual(mutations(client), []);
  });
});

test("a governed rollback release without domain-core evidence audits and promotes", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    const result = audit(files, client, verifyDomainCoreBundles);
    assert.equal(
      result.release.identity.assets.some((asset) =>
        asset.name.includes("-domain-core"),
      ),
      false,
    );
    assert.equal(
      JSON.parse(readFileSync(files.receiptPath, "utf8")).domainCoreProfile,
      ROLLBACK_PROFILE,
    );
    client.calls.length = 0;
    assert.deepEqual(promoteAuditedRelease(files.receiptPath, { client }), {
      promoted: true,
      promotionApplied: true,
    });
  }, ROLLBACK_PROFILE);
});

test("a declared profile that mismatches the published asset set fails closed", () => {
  // public-production declared for a rollback-shaped release: every missing
  // domain-core evidence asset blocks the audit.
  withFixture((files) => {
    const client = new FakeClient(files);
    assert.throws(
      () => audit(files, client, () => {}, PUBLIC_PROFILE),
      /asset set mismatch/u,
    );
    assert.equal(mutations(client).length, 0);
  }, ROLLBACK_PROFILE);

  // rollback declared for a fully evidenced release: every published bundle is
  // still downloaded and cryptographically verified, never skipped.
  withFixture((files) => {
    const client = new FakeClient(files);
    assert.throws(
      () => audit(files, client, verifyDomainCoreBundles, ROLLBACK_PROFILE),
      /unsupported fake command: attestation/u,
    );
    assert.equal(mutations(client).length, 0);
  });
});

test("an ungoverned domain-core profile is rejected before any release lookup", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    assert.throws(
      () => audit(files, client, () => {}, "public-canary"),
      /governed public-production/u,
    );
    assert.equal(client.calls.length, 0);
  });
});

test("a post-edit latest substitution is detected", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    audit(files, client);
    client.calls.length = 0;
    client.editHook = (_args, instance) => {
      instance.latest = true;
      instance.assets.set(
        `OpenBurnBar-${VERSION}-Android.aab`,
        Buffer.from("raced"),
      );
      return { status: 0, stdout: "", stderr: "" };
    };
    assert.throws(
      () => promoteAuditedRelease(files.receiptPath, { client }),
      /GitHub latest release is not the unchanged audited release/u,
    );
    assert.equal(mutations(client).length, 1);
  });
});
