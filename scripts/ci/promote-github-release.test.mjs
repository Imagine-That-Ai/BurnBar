import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  auditExistingRelease,
  expectedReleaseAssets,
  promoteAuditedRelease,
  verifyDomainCoreBundles,
} from "./promote-github-release.mjs";

const REPOSITORY = "Imagine-That-Ai/BurnBar";
const VERSION = "1.2.3";
const TAG = `v${VERSION}`;
const COMMIT = "a".repeat(40);
const APPLE_TEAM_ID = "4Y367DF25B";
const APPLE_SIGNING_AUTHORITY =
  "Developer ID Application: Imagine That AI Limited Liability Company (4Y367DF25B)";
const APPLE_SIGNING_CERTIFICATE_SHA1 =
  "2FAA2102B33D02ED5F1A3D34EF51B210A4398ECA";
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
  put(
    "developer-id-signing-receipt.json",
    `${JSON.stringify({
      schemaVersion: 1,
      distribution: "developer-id",
      teamId: APPLE_TEAM_ID,
      appGroup: "group.com.openburnbar.app",
      keychainGroup: `${APPLE_TEAM_ID}.com.openburnbar.app`,
      signingIdentity: APPLE_SIGNING_AUTHORITY,
      signingCertificateSha1: APPLE_SIGNING_CERTIFICATE_SHA1,
      host: {
        bundleIdentifier: "com.openburnbar.app",
        profileExpiration: "2099-08-13T00:00:00Z",
        profileSha256: "a".repeat(64),
        signature: {
          authority: "Developer ID Application",
          hardenedRuntime: true,
          libraryValidation: true,
          secureTimestamp: true,
        },
      },
      safariExtension: {
        bundleIdentifier: "com.openburnbar.app.safari-extension",
        profileExpiration: "2099-08-13T00:00:00Z",
        profileSha256: "b".repeat(64),
        signature: {
          authority: "Developer ID Application",
          hardenedRuntime: true,
          libraryValidation: true,
        },
      },
      verification: {
        embeddedProfilesByteEqual: true,
        getTaskAllow: false,
        platform: "OSX",
        profileCertificateMembership: true,
        signingCertificateSha1Matched: true,
        strictDeepNestedSignatures: true,
      },
    })}\n`,
  );

  const sparkle = "sparkle-signature";
  put(
    "latest-macos.json",
    `${JSON.stringify(
      {
        version: VERSION,
        commit: COMMIT,
        dmg,
        zip,
        correspondingSource: source,
        length: assets.get(dmg).length,
        sha256: hash("sha256", assets.get(dmg)),
        sparkleEdSignature: sparkle,
      },
      null,
      2,
    )}\n`,
  );
  put(
    "appcast.xml",
    `<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString><enclosure sparkle:edSignature="${sparkle}" />`,
  );
  put(
    "release-metadata.json",
    `${JSON.stringify({
      version: VERSION,
      tag: TAG,
      commit: COMMIT,
      channel: "direct-download",
      correspondingSource: source,
      appcast: "appcast.xml",
      latestMetadata: "latest-macos.json",
      developerIdSigningReceipt: "developer-id-signing-receipt.json",
      sparkleEdSignaturePresent: true,
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
    "developer-id-signing-receipt.json",
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
      [...this.assets.keys()]
        .sort()
        .map((name, index) => [name, 1000 + index]),
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

test("audits the exact complete remote release and writes an immutable receipt", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    let domainVerificationCalls = 0;
    const result = audit(files, client, () => {
      domainVerificationCalls += 1;
    });
    assert.equal(domainVerificationCalls, 1);
    assert.equal(result.release.identity.assets.length, files.assets.size);
    assert.equal(readFileSync(files.receiptPath, "utf8").includes(COMMIT), true);
    assert.equal(mutations(client).length, 0);
    assert.deepEqual(
      new Set(
        client.calls
          .filter(
            (args) => args[0] === "release" && args[1] === "download",
          )
          .map((args) => args[args.indexOf("--pattern") + 1]),
      ),
      new Set(files.assets.keys()),
    );
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

test("a substituted Developer ID signing receipt fails before promotion", () => {
  withFixture((files) => {
    const client = new FakeClient(files);
    const receiptName = "developer-id-signing-receipt.json";
    const receipt = JSON.parse(client.assets.get(receiptName).toString("utf8"));
    receipt.signingCertificateSha1 = "0".repeat(40);
    const receiptBytes = Buffer.from(`${JSON.stringify(receipt)}\n`);
    client.assets.set(receiptName, receiptBytes);
    const checksumsName = `checksums-v${VERSION}.txt`;
    const checksums = client.assets
      .get(checksumsName)
      .toString("utf8")
      .split("\n")
      .map((line) => {
        if (!line.endsWith(`/tmp/${receiptName}`)) return line;
        const algorithm = line.slice(0, line.indexOf(" ")).length === 64
          ? "sha256"
          : "sha512";
        return `${hash(algorithm, receiptBytes)}  /tmp/${receiptName}`;
      })
      .join("\n");
    client.assets.set(checksumsName, Buffer.from(checksums));
    assert.throws(
      () => audit(files, client),
      /does not bind the protected Developer ID signer/u,
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
      [
        "release",
        "edit",
        TAG,
        "--repo",
        REPOSITORY,
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
