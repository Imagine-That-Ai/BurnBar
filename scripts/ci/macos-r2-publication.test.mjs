import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  createHash,
  generateKeyPairSync,
  sign as signBytes,
} from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  lstatSync,
  readFileSync,
  readlinkSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  preflightR2Publication,
  preflightR2RollbackPublication,
  sealR2PublicationManifest,
  verifyPublicR2Publication,
  verifyPublicR2RollbackPublication,
} from "./macos-r2-publication.mjs";
import { expectedReleaseAssets } from "./promote-github-release.mjs";

const VERSION = "1.2.3";
const TAG = `v${VERSION}`;
const COMMIT = "a".repeat(40);
const REPOSITORY = "Imagine-That-Ai/BurnBar";
const ROLLBACK_PROFILE = "public-production-rollback";
const LEGACY_UPDATE_BASE_URL =
  "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download";
const PUBLIC_BASE_URL = "https://downloads.burnbar.ai";
const ZIP_FIXTURE_SCRIPT = String.raw`
import json
import sys
import zipfile

archive = sys.argv[1]
entries = json.load(sys.stdin)
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
    for entry in entries:
        info = zipfile.ZipInfo(entry["name"])
        info.create_system = 3
        info.external_attr = entry["mode"] << 16
        output.writestr(info, entry.get("content", "").encode("utf-8"))
`;

function hash(value) {
  return createHash("sha256").update(value).digest("hex");
}

function hash512(value) {
  return createHash("sha512").update(value).digest("hex");
}

function fixture({
  updateBaseUrl = PUBLIC_BASE_URL,
  signatureKeyMismatch = false,
  zipLayout = "canonical",
} = {}) {
  const root = mkdtempSync(join(tmpdir(), "openburnbar-r2-publication-test-"));
  const assetDirectory = join(root, "assets");
  const receiptPath = join(root, "promotion-receipt.json");
  mkdirSync(assetDirectory);

  const assets = new Map();
  const put = (name, value) => {
    assets.set(name, Buffer.from(value));
  };
  const dmg = `OpenBurnBar-${VERSION}-macOS.dmg`;
  const zip = `OpenBurnBar-${VERSION}-macOS.zip`;
  const source = `OpenBurnBar-${VERSION}-corresponding-source.tar.gz`;
  const rollback = `OpenBurnBar-${VERSION}-legacy-rollback.zip`;
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const rawPublicKey = publicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32);
  const publicKeyBase64 = rawPublicKey.toString("base64");
  put(dmg, "signed-notarized-dmg");
  const plist = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<plist><dict>",
    "<key>SUPublicEDKey</key>",
    `<string>${publicKeyBase64}</string>`,
    "</dict></plist>",
  ].join("");
  const zipEntries = [
    { name: "OpenBurnBar.app/", mode: 0o040755 },
    { name: "OpenBurnBar.app/Contents/", mode: 0o040755 },
    {
      name: "OpenBurnBar.app/Contents/Info.plist",
      mode: 0o100644,
      content: plist,
    },
    // Every shipped bundle carries versioned frameworks, and those cannot be
    // expressed without symlinks -- codesign seals Versions/Current and the
    // aliases beside it. Keeping them in the canonical fixture means every
    // happy-path assertion below also proves a real bundle still passes.
    {
      name: "OpenBurnBar.app/Contents/Frameworks/G.framework/Versions/A/G",
      mode: 0o100644,
      content: "framework",
    },
    {
      name: "OpenBurnBar.app/Contents/Frameworks/G.framework/Versions/Current",
      mode: 0o120777,
      content: "A",
    },
    {
      name: "OpenBurnBar.app/Contents/Frameworks/G.framework/G",
      mode: 0o120777,
      content: "Versions/Current/G",
    },
  ];
  if (zipLayout === "decoy") {
    zipEntries.push(
      { name: "Decoy/", mode: 0o040755 },
      { name: "Decoy/OpenBurnBar.app/", mode: 0o040755 },
      { name: "Decoy/OpenBurnBar.app/Contents/", mode: 0o040755 },
      {
        name: "Decoy/OpenBurnBar.app/Contents/Info.plist",
        mode: 0o100644,
        content: plist,
      },
    );
  } else if (zipLayout === "duplicate") {
    zipEntries.push({
      name: "OpenBurnBar.app/Contents/Info.plist",
      mode: 0o100644,
      content: plist,
    });
  } else if (zipLayout === "case-collision") {
    zipEntries.push({
      name: "OpenBurnBar.app/Contents/info.plist",
      mode: 0o100644,
      content: plist,
    });
  } else if (zipLayout === "symlink") {
    zipEntries.push({
      name: "OpenBurnBar.app/Contents/Frameworks/escape",
      mode: 0o120777,
      content: "../../../../outside",
    });
  } else if (zipLayout === "symlink-chain") {
    // Aliases that collapse the path, so a later entry's name stays inside the
    // bundle while the physical location it resolves to does not.
    zipEntries.push(
      { name: "OpenBurnBar.app/a", mode: 0o120777, content: "." },
      { name: "OpenBurnBar.app/a/b", mode: 0o120777, content: "." },
      {
        name: "OpenBurnBar.app/a/b/payload",
        mode: 0o100644,
        content: "payload",
      },
    );
  } else if (zipLayout === "symlink-oversized") {
    zipEntries.push({
      name: "OpenBurnBar.app/huge",
      mode: 0o120777,
      content: "A".repeat(8192),
    });
  } else if (zipLayout === "symlink-absolute") {
    zipEntries.push({
      name: "OpenBurnBar.app/Contents/Frameworks/absolute",
      mode: 0o120777,
      content: "/etc/passwd",
    });
  } else if (zipLayout === "traversal") {
    zipEntries.push({
      name: "OpenBurnBar.app/../escape",
      mode: 0o100644,
      content: "escape",
    });
  } else if (zipLayout !== "canonical") {
    throw new Error(`unknown ZIP fixture layout: ${zipLayout}`);
  }
  const zipPath = join(root, zip);
  const zipResult = spawnSync("python3", ["-c", ZIP_FIXTURE_SCRIPT, zipPath], {
    input: JSON.stringify(zipEntries),
    encoding: "utf8",
  });
  assert.equal(zipResult.status, 0, zipResult.stderr);
  const signatureVerifierPath = join(root, "verify-code-signature");
  writeFileSync(
    signatureVerifierPath,
    `#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == "1" ]]
[[ "\${1##*/}" == "OpenBurnBar.app" ]]
[[ -f "$1/Contents/Info.plist" ]]
`,
    {
      encoding: "utf8",
    },
  );
  chmodSync(signatureVerifierPath, 0o755);
  put(zip, readFileSync(zipPath));
  put(source, "corresponding-source");
  put(`${source}.sha256`, `${hash(assets.get(source))}  ${source}\n`);
  put(rollback, "legacy-rollback");
  put(`sbom-v${VERSION}.spdx.json`, '{"spdxVersion":"SPDX-2.3"}\n');
  put(`openburnbar-v${VERSION}.vex.json`, "{}\n");
  put(`NOTICES-v${VERSION}.txt`, "notices\n");
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
      runner_name: "GitHub Actions fixture",
      runner_os: "macOS",
      sparkleEdSignaturePresent: true,
      tag: TAG,
      updateBaseUrl,
      version: VERSION,
    })}\n`,
  );
  put(
    "latest-macos.json",
    `${JSON.stringify({
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
      sha256: hash(assets.get(dmg)),
      sparkleEdSignature: "",
      version: VERSION,
      zip,
    })}\n`,
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
      `<enclosure url="${updateBaseUrl}/${dmg}" length="${assets.get(dmg).length}" type="application/x-apple-diskimage" sparkle:edSignature="" />`,
      "</item>",
    ].join(""),
  );
  const signingKey = signatureKeyMismatch
    ? generateKeyPairSync("ed25519").privateKey
    : privateKey;
  const signature = signBytes(null, assets.get(dmg), signingKey).toString(
    "base64",
  );
  put(
    "latest-macos.json",
    Buffer.from(
      assets
        .get("latest-macos.json")
        .toString("utf8")
        .replace(
          '"sparkleEdSignature":""',
          `"sparkleEdSignature":"${signature}"`,
        ),
    ),
  );
  put(
    "appcast.xml",
    Buffer.from(
      assets
        .get("appcast.xml")
        .toString("utf8")
        .replace(
          'sparkle:edSignature=""',
          `sparkle:edSignature="${signature}"`,
        ),
    ),
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
        `${hash(assets.get(name))}  ${name}`,
        `${hash512(assets.get(name))}  ${name}`,
      ])
      .join("\n")}\n`,
  );

  for (const name of expectedReleaseAssets(VERSION, ROLLBACK_PROFILE)
    .required) {
    if (!assets.has(name)) put(name, `fixture:${name}`);
  }
  for (const [name, bytes] of assets) {
    writeFileSync(join(assetDirectory, name), bytes);
  }
  const identityAssets = [...assets.entries()]
    .map(([name, bytes], index) => ({
      id: 1000 + index,
      name,
      size: bytes.length,
      digest: `sha256:${hash(bytes)}`,
    }))
    .sort((left, right) => left.name.localeCompare(right.name));
  writeFileSync(
    receiptPath,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        repository: REPOSITORY,
        tag: TAG,
        version: VERSION,
        commit: COMMIT,
        notesSha256: hash("release notes\n"),
        domainCoreProfile: ROLLBACK_PROFILE,
        releaseIdentity: {
          releaseID: 9001,
          assets: identityAssets,
        },
      },
      null,
      2,
    )}\n`,
  );

  return {
    root,
    assetDirectory,
    receiptPath,
    assets,
    signatureVerifierPath,
    verifyAppSignature: (appBundlePath) => {
      assert.equal(appBundlePath.split("/").at(-1), "OpenBurnBar.app");
      assert.equal(
        existsSync(join(appBundlePath, "Contents", "Info.plist")),
        true,
      );
      // The canonical fixture ships the framework aliases every signed bundle
      // carries. Merely accepting that ZIP proves nothing about how the entries
      // came back, so assert the node type and target here: without this the
      // suite still passes when the extractor falls through and writes "A" into
      // a regular file, which is the regression the fixture exists to catch.
      const framework = join(
        appBundlePath,
        "Contents",
        "Frameworks",
        "G.framework",
      );
      for (const [alias, target] of [
        ["Versions/Current", "A"],
        ["G", "Versions/Current/G"],
      ]) {
        const link = join(framework, ...alias.split("/"));
        assert.equal(lstatSync(link).isSymbolicLink(), true, alias);
        assert.equal(readlinkSync(link), target, alias);
      }
      assert.equal(
        lstatSync(join(framework, "Versions", "A", "G")).isFile(),
        true,
      );
    },
  };
}

function preflight(files, verifyAppSignature = files.verifyAppSignature) {
  return preflightR2Publication({
    assetDirectory: files.assetDirectory,
    receiptPath: files.receiptPath,
    version: VERSION,
    tag: TAG,
    commit: COMMIT,
    publicBaseUrl: PUBLIC_BASE_URL,
    verifyAppSignature,
  });
}

function rollbackPreflight(
  files,
  appcastPath = join(files.assetDirectory, "appcast.xml"),
  receiptPath = files.receiptPath,
) {
  return preflightR2RollbackPublication({
    assetDirectory: files.assetDirectory,
    receiptPath,
    appcastPath,
    derivedDirectory: join(files.root, "rollback-derived"),
    version: VERSION,
    tag: TAG,
    commit: COMMIT,
    publicBaseUrl: PUBLIC_BASE_URL,
    verifyAppSignature: files.verifyAppSignature,
  });
}

function runForwardPublisher(
  files,
  { prior, expectedVersion, expectedCommit, nodeFailureMode = "none" },
) {
  const state = join(files.root, "forward-provider-state");
  const bin = join(files.root, "forward-provider-bin");
  const home = join(files.root, "forward-provider-home");
  const wranglerLog = join(files.root, "forward-provider-wrangler.log");
  const putCount = join(files.root, "forward-provider-put-count");
  mkdirSync(state);
  mkdirSync(bin);
  mkdirSync(home);
  for (const [name, bytes] of prior) writeFileSync(join(state, name), bytes);

  const curl = join(bin, "curl");
  writeFileSync(
    curl,
    `#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out|--header|--connect-timeout|--max-time) shift 2 ;;
    --location|--show-error|--silent) shift ;;
    *) url="$1"; shift ;;
  esac
done
name="\${url%%\\?*}"
name="\${name##*/}"
path="$FAKE_R2_STATE/$name"
if [[ -f "$path" ]]; then
  cp "$path" "$output"
  printf '200'
else
  printf '404'
fi
`,
  );
  chmodSync(curl, 0o755);

  const wrangler = join(bin, "wrangler");
  writeFileSync(
    wrangler,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$WRANGLER_LOG"
operation="$3"
target="$4"
name="\${target#*/}"
if [[ "$operation" == "put" ]]; then
  count=0
  [[ ! -f "$WRANGLER_PUT_COUNT" ]] || count="$(<"$WRANGLER_PUT_COUNT")"
  count=$((count + 1))
  printf '%s\\n' "$count" >"$WRANGLER_PUT_COUNT"
  file=""
  shift 4
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--file" ]]; then file="$2"; break; fi
    shift
  done
  cp "$file" "$FAKE_R2_STATE/$name"
elif [[ "$operation" == "delete" ]]; then
  rm -f "$FAKE_R2_STATE/$name"
fi
`,
  );
  chmodSync(wrangler, 0o755);

  const node = join(bin, "node");
  writeFileSync(
    node,
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "$NODE_FAILURE_MODE" == "verify-public" &&
  "$*" == *"macos-r2-publication.mjs verify-public"* ]]; then
  echo "injected post-publication verification failure" >&2
  exit 73
fi
if [[ "$NODE_FAILURE_MODE" == "upload-plan" &&
  "\${1:-}" == "--input-type=module" ]]; then
  echo "injected upload-plan generator failure" >&2
  exit 74
fi
exec "$REAL_NODE" "$@"
`,
  );
  chmodSync(node, 0o755);

  const result = spawnSync("bash", ["scripts/upload-macos-downloads-r2.sh"], {
    encoding: "utf8",
    env: {
      ...process.env,
      FAKE_R2_STATE: state,
      HOME: home,
      NODE_ENV: "test",
      NODE_FAILURE_MODE: nodeFailureMode,
      NODE_TEST_CONTEXT: process.env.NODE_TEST_CONTEXT ?? "child-v8",
      OPENBURNBAR_EXPECTED_LIVE_COMMIT: expectedCommit,
      OPENBURNBAR_EXPECTED_LIVE_VERSION: expectedVersion,
      OPENBURNBAR_RELEASE_ASSET_DIR: files.assetDirectory,
      OPENBURNBAR_RELEASE_COMMIT: COMMIT,
      OPENBURNBAR_RELEASE_RECEIPT: files.receiptPath,
      OPENBURNBAR_RELEASE_TAG: TAG,
      OPENBURNBAR_RELEASE_VERSION: VERSION,
      OPENBURNBAR_R2_CURL_BIN: curl,
      OPENBURNBAR_R2_PUBLIC_BASE_URL: PUBLIC_BASE_URL,
      OPENBURNBAR_TEST_CODESIGN_VERIFY_BIN: files.signatureVerifierPath,
      OPENBURNBAR_VERIFY_ATTEMPTS: "1",
      OPENBURNBAR_VERIFY_DELAY_MS: "0",
      OPENBURNBAR_VERIFY_REQUEST_TIMEOUT_MS: "50",
      PATH: `${bin}:${process.env.PATH}`,
      REAL_NODE: process.execPath,
      WRANGLER_BIN: wrangler,
      WRANGLER_LOG: wranglerLog,
      WRANGLER_PUT_COUNT: putCount,
    },
  });
  return {
    result,
    state,
    wranglerCalls: () =>
      existsSync(wranglerLog) ? readFileSync(wranglerLog, "utf8") : "",
  };
}

function mutablePointerFixture(version, commit) {
  return new Map([
    ["release-metadata.json", Buffer.from('{"prior":"metadata"}\n')],
    [
      "latest-macos.json",
      Buffer.from(`${JSON.stringify({ version, commit })}\n`),
    ],
    ["appcast.xml", Buffer.from("<rss>prior-appcast</rss>\n")],
  ]);
}

test("consumes the real promotion receipt schema and emits ordered R2 groups", () => {
  const files = fixture();
  try {
    const manifest = preflight(files);
    assert.deepEqual(
      manifest.groups.immutable.map((entry) => entry.name),
      [
        `OpenBurnBar-${VERSION}-macOS.dmg`,
        `OpenBurnBar-${VERSION}-macOS.zip`,
        `checksums-v${VERSION}.txt`,
        `sbom-v${VERSION}.spdx.json`,
        `OpenBurnBar-${VERSION}-corresponding-source.tar.gz`,
        `OpenBurnBar-${VERSION}-corresponding-source.tar.gz.sha256`,
      ],
    );
    assert.deepEqual(
      manifest.groups.metadata.map((entry) => entry.name),
      ["release-metadata.json"],
    );
    assert.deepEqual(
      manifest.groups.discovery.map((entry) => entry.name),
      ["latest-macos.json", "appcast.xml"],
    );
    assert.equal(manifest.commit, COMMIT);
    assert.equal(
      manifest.expected.sha256,
      hash(files.assets.get(`OpenBurnBar-${VERSION}-macOS.dmg`)),
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("missing final discovery artifact fails before the first provider call", () => {
  const files = fixture();
  try {
    unlinkSync(join(files.assetDirectory, "latest-macos.json"));
    const bin = join(files.root, "bin");
    const wranglerLog = join(files.root, "wrangler.log");
    mkdirSync(bin);
    const wrangler = join(bin, "wrangler");
    writeFileSync(
      wrangler,
      '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$WRANGLER_LOG"\n',
    );
    chmodSync(wrangler, 0o755);
    const result = spawnSync("bash", ["scripts/upload-macos-downloads-r2.sh"], {
      encoding: "utf8",
      env: {
        ...process.env,
        OPENBURNBAR_RELEASE_ASSET_DIR: files.assetDirectory,
        OPENBURNBAR_RELEASE_RECEIPT: files.receiptPath,
        OPENBURNBAR_RELEASE_VERSION: VERSION,
        OPENBURNBAR_RELEASE_TAG: TAG,
        OPENBURNBAR_RELEASE_COMMIT: COMMIT,
        OPENBURNBAR_EXPECTED_LIVE_COMMIT: "absent",
        OPENBURNBAR_EXPECTED_LIVE_VERSION: "absent",
        OPENBURNBAR_R2_PUBLIC_BASE_URL: PUBLIC_BASE_URL,
        WRANGLER_BIN: wrangler,
        WRANGLER_LOG: wranglerLog,
      },
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /latest-macos\.json/u);
    assert.equal(
      existsSync(wranglerLog) ? readFileSync(wranglerLog, "utf8") : "",
      "",
      "preflight failure must make zero Wrangler provider calls",
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("forward publisher rejects a downgrade before the first provider mutation", () => {
  const files = fixture();
  try {
    const currentVersion = "2.0.0";
    const currentCommit = "b".repeat(40);
    const run = runForwardPublisher(files, {
      prior: mutablePointerFixture(currentVersion, currentCommit),
      expectedVersion: currentVersion,
      expectedCommit: currentCommit,
    });
    assert.notEqual(run.result.status, 0);
    assert.match(run.result.stderr, /cannot downgrade/u);
    assert.equal(run.wranglerCalls(), "");
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("forward publisher rejects the same version with a different commit before mutation", () => {
  const files = fixture();
  try {
    const currentCommit = "b".repeat(40);
    const run = runForwardPublisher(files, {
      prior: mutablePointerFixture(VERSION, currentCommit),
      expectedVersion: VERSION,
      expectedCommit: currentCommit,
    });
    assert.notEqual(run.result.status, 0);
    assert.match(run.result.stderr, /exact same version and commit/u);
    assert.equal(run.wranglerCalls(), "");
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("post-publication verification failure restores all prior mutable bytes", () => {
  const files = fixture();
  try {
    const currentVersion = "1.2.2";
    const currentCommit = "b".repeat(40);
    const prior = mutablePointerFixture(currentVersion, currentCommit);
    const run = runForwardPublisher(files, {
      prior,
      expectedVersion: currentVersion,
      expectedCommit: currentCommit,
      nodeFailureMode: "verify-public",
    });
    assert.notEqual(run.result.status, 0);
    assert.match(run.result.stderr, /post-publication verification failure/u);
    for (const [name, bytes] of prior) {
      assert.deepEqual(readFileSync(join(run.state, name)), bytes);
    }
    assert.match(run.wranglerCalls(), /appcast\.xml/u);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("post-publication failure deletes mutable objects that were previously absent", () => {
  const files = fixture();
  try {
    const run = runForwardPublisher(files, {
      prior: new Map(),
      expectedVersion: "absent",
      expectedCommit: "absent",
      nodeFailureMode: "verify-public",
    });
    assert.notEqual(run.result.status, 0);
    for (const name of [
      "release-metadata.json",
      "latest-macos.json",
      "appcast.xml",
    ]) {
      assert.equal(existsSync(join(run.state, name)), false);
    }
    assert.match(run.wranglerCalls(), /object delete/u);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("upload-plan generation failure makes zero provider mutations", () => {
  const files = fixture();
  try {
    const run = runForwardPublisher(files, {
      prior: new Map(),
      expectedVersion: "absent",
      expectedCommit: "absent",
      nodeFailureMode: "upload-plan",
    });
    assert.notEqual(run.result.status, 0);
    assert.match(run.result.stderr, /upload-plan generator failure/u);
    assert.equal(run.wranglerCalls(), "");
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("public verification retries stale cache bytes and proves the exact candidate", async () => {
  const files = fixture();
  try {
    const manifest = preflight(files);
    let staleServed = false;
    let delays = 0;
    const result = await verifyPublicR2Publication(manifest, {
      attempts: 3,
      delayMs: 0,
      delayImpl: async () => {
        delays += 1;
      },
      verifyAppSignature: files.verifyAppSignature,
      fetchImpl: async (url) => {
        const name = decodeURIComponent(
          new URL(url).pathname.split("/").at(-1),
        );
        let bytes = files.assets.get(name);
        assert(bytes, `unexpected public asset request ${name}`);
        if (name === "latest-macos.json" && !staleServed) {
          staleServed = true;
          bytes = Buffer.from('{"version":"stale"}\n');
        }
        return new Response(bytes, {
          status: 200,
          headers: { "content-length": String(bytes.length) },
        });
      },
    });
    assert.equal(result.verified, true);
    assert.equal(result.attempts, 2);
    assert.equal(result.commit, COMMIT);
    assert.equal(delays, 1);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("public verification aborts a stalled request within its declared timeout", async () => {
  const files = fixture();
  try {
    const manifest = preflight(files);
    await assert.rejects(
      verifyPublicR2Publication(manifest, {
        attempts: 1,
        delayMs: 0,
        requestTimeoutMs: 10,
        verifyAppSignature: files.verifyAppSignature,
        fetchImpl: async (_url, { signal }) =>
          await new Promise((_resolve, reject) => {
            const keepAlive = setTimeout(
              () => reject(new Error("timeout signal did not fire")),
              1_000,
            );
            signal.addEventListener(
              "abort",
              () => {
                clearTimeout(keepAlive);
                reject(signal.reason);
              },
              { once: true },
            );
          }),
      }),
      /public R2 release verification failed after 1 attempts/u,
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("local validator rejects a metadata commit substitution", () => {
  const files = fixture();
  try {
    const metadataPath = join(files.assetDirectory, "release-metadata.json");
    const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
    metadata.commit = "b".repeat(40);
    writeFileSync(metadataPath, `${JSON.stringify(metadata)}\n`);
    assert.throws(
      () => preflight(files),
      /does not match its audited size and digest|does not bind/u,
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("forward preflight rejects feeds bound to a different update host", () => {
  const files = fixture({ updateBaseUrl: LEGACY_UPDATE_BASE_URL });
  try {
    assert.throws(() => preflight(files), /updateBaseUrl must exactly match/u);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("forward preflight rejects a DMG signature that does not verify", () => {
  const files = fixture({ signatureKeyMismatch: true });
  try {
    assert.throws(() => preflight(files), /does not verify against/u);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

for (const [zipLayout, expectedError] of [
  ["decoy", /canonical root OpenBurnBar\.app/u],
  ["duplicate", /duplicate or filesystem-colliding paths/u],
  ["case-collision", /duplicate or filesystem-colliding paths/u],
  // A bundle-internal symlink is legitimate and lives in the canonical fixture
  // below; what must stay rejected is a link that leaves the bundle or names an
  // absolute path.
  ["symlink", /symlink escapes the bundle root/u],
  ["symlink-absolute", /unsafe symlink target/u],
  ["symlink-chain", /descends through a symlink/u],
  ["symlink-oversized", /oversized symlink target/u],
  ["traversal", /canonical root OpenBurnBar\.app/u],
]) {
  test(`forward preflight rejects a ${zipLayout} app ZIP layout`, () => {
    const files = fixture({ zipLayout });
    try {
      assert.throws(() => preflight(files), expectedError);
    } finally {
      rmSync(files.root, { recursive: true, force: true });
    }
  });
}

test("forward preflight rejects an unsigned canonical app bundle", () => {
  const files = fixture();
  try {
    assert.throws(
      () =>
        preflight(files, () => {
          throw new Error("fixture signature rejection");
        }),
      /fixture signature rejection/u,
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("forward preflight rejects Info.plist key drift during signature verification", () => {
  const files = fixture();
  try {
    assert.throws(
      () =>
        preflight(files, (appBundlePath) => {
          writeFileSync(
            join(appBundlePath, "Contents", "Info.plist"),
            "<plist><dict><key>SUPublicEDKey</key><string>drift</string></dict></plist>",
          );
        }),
      /Info\.plist changed during code-signature verification/u,
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("seals audited forward inputs against later handoff mutation", () => {
  const files = fixture();
  try {
    const manifest = preflight(files);
    const sealed = sealR2PublicationManifest(
      manifest,
      join(files.root, "sealed"),
    );
    writeFileSync(
      join(files.assetDirectory, "latest-macos.json"),
      '{"version":"raced"}\n',
    );
    const latest = sealed.groups.discovery.find(
      (entry) => entry.name === "latest-macos.json",
    );
    assert.equal(
      JSON.parse(readFileSync(latest.path, "utf8")).version,
      VERSION,
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("partial forward publication restores the exact prior mutable pointer set", () => {
  const files = fixture();
  try {
    const state = join(files.root, "forward-public-state");
    const bin = join(files.root, "forward-bin");
    const wranglerLog = join(files.root, "forward-wrangler.log");
    const putCount = join(files.root, "forward-put-count");
    mkdirSync(state);
    mkdirSync(bin);
    const currentVersion = "1.2.2";
    const currentCommit = "b".repeat(40);
    const prior = new Map([
      ["release-metadata.json", Buffer.from('{"prior":"metadata"}\n')],
      [
        "latest-macos.json",
        Buffer.from(
          `${JSON.stringify({
            version: currentVersion,
            commit: currentCommit,
          })}\n`,
        ),
      ],
      ["appcast.xml", Buffer.from("<rss>prior-appcast</rss>\n")],
    ]);
    for (const [name, bytes] of prior) writeFileSync(join(state, name), bytes);

    const curl = join(bin, "curl");
    writeFileSync(
      curl,
      `#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out|--header|--connect-timeout|--max-time) shift 2 ;;
    --location|--show-error|--silent) shift ;;
    *) url="$1"; shift ;;
  esac
done
name="\${url%%\\?*}"
name="\${name##*/}"
path="$FAKE_R2_STATE/$name"
if [[ -f "$path" ]]; then
  cp "$path" "$output"
  printf '200'
else
  printf '404'
fi
`,
    );
    chmodSync(curl, 0o755);

    const wrangler = join(bin, "wrangler");
    writeFileSync(
      wrangler,
      `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$WRANGLER_LOG"
operation="$3"
target="$4"
name="\${target#*/}"
if [[ "$operation" == "put" ]]; then
  count=0
  [[ ! -f "$WRANGLER_PUT_COUNT" ]] || count="$(<"$WRANGLER_PUT_COUNT")"
  count=$((count + 1))
  printf '%s\\n' "$count" >"$WRANGLER_PUT_COUNT"
  if [[ "$count" == "8" ]]; then
    exit 42
  fi
  file=""
  shift 4
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--file" ]]; then file="$2"; break; fi
    shift
  done
  cp "$file" "$FAKE_R2_STATE/$name"
elif [[ "$operation" == "delete" ]]; then
  rm -f "$FAKE_R2_STATE/$name"
fi
`,
    );
    chmodSync(wrangler, 0o755);

    const result = spawnSync("bash", ["scripts/upload-macos-downloads-r2.sh"], {
      encoding: "utf8",
      env: {
        ...process.env,
        FAKE_R2_STATE: state,
        OPENBURNBAR_EXPECTED_LIVE_COMMIT: currentCommit,
        OPENBURNBAR_EXPECTED_LIVE_VERSION: currentVersion,
        OPENBURNBAR_RELEASE_ASSET_DIR: files.assetDirectory,
        OPENBURNBAR_RELEASE_COMMIT: COMMIT,
        OPENBURNBAR_RELEASE_RECEIPT: files.receiptPath,
        OPENBURNBAR_RELEASE_TAG: TAG,
        OPENBURNBAR_RELEASE_VERSION: VERSION,
        OPENBURNBAR_R2_CURL_BIN: curl,
        OPENBURNBAR_R2_PUBLIC_BASE_URL: PUBLIC_BASE_URL,
        OPENBURNBAR_TEST_CODESIGN_VERIFY_BIN: files.signatureVerifierPath,
        OPENBURNBAR_VERIFY_ATTEMPTS: "1",
        OPENBURNBAR_VERIFY_DELAY_MS: "0",
        OPENBURNBAR_VERIFY_REQUEST_TIMEOUT_MS: "50",
        NODE_ENV: "test",
        NODE_TEST_CONTEXT: process.env.NODE_TEST_CONTEXT ?? "child-v8",
        WRANGLER_BIN: wrangler,
        WRANGLER_LOG: wranglerLog,
        WRANGLER_PUT_COUNT: putCount,
      },
    });
    assert.notEqual(result.status, 0);
    for (const [name, bytes] of prior) {
      assert.deepEqual(readFileSync(join(state, name)), bytes);
    }
    const log = readFileSync(wranglerLog, "utf8");
    assert.match(log, /release-metadata\.json/u);
    assert.match(log, /latest-macos\.json/u);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("rollback publication preserves audited R2-bound pointers and activates appcast last", () => {
  const files = fixture();
  try {
    const manifest = rollbackPreflight(files);
    assert.deepEqual(
      manifest.groups.metadata.map((entry) => entry.name),
      ["release-metadata.json"],
    );
    assert.deepEqual(
      manifest.groups.discovery.map((entry) => entry.name),
      ["latest-macos.json", "appcast.xml"],
    );
    assert.deepEqual(
      manifest.verifyOnly.map((entry) => entry.name),
      [
        `OpenBurnBar-${VERSION}-macOS.dmg`,
        `OpenBurnBar-${VERSION}-macOS.zip`,
        `OpenBurnBar-${VERSION}-corresponding-source.tar.gz`,
      ],
    );
    const latest = JSON.parse(
      readFileSync(manifest.groups.discovery[0].path, "utf8"),
    );
    const metadata = JSON.parse(
      readFileSync(manifest.groups.metadata[0].path, "utf8"),
    );
    const appcast = readFileSync(manifest.groups.discovery[1].path, "utf8");
    assert.equal(latest.downloadUrl, `${PUBLIC_BASE_URL}/${latest.dmg}`);
    assert.equal(latest.appcastUrl, `${PUBLIC_BASE_URL}/appcast.xml`);
    assert.equal(
      latest.releaseNotesUrl,
      `${PUBLIC_BASE_URL}/release-metadata.json`,
    );
    assert.equal(metadata.updateBaseUrl, PUBLIC_BASE_URL);
    assert.match(appcast, new RegExp(PUBLIC_BASE_URL, "u"));
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("rollback preflight rejects a legacy feed bound to another host", () => {
  const files = fixture({ updateBaseUrl: LEGACY_UPDATE_BASE_URL });
  try {
    assert.throws(
      () => rollbackPreflight(files),
      /updateBaseUrl must exactly match/u,
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("rollback publication accepts the narrow legacy target audit receipt", () => {
  const files = fixture();
  try {
    const promotionReceipt = JSON.parse(
      readFileSync(files.receiptPath, "utf8"),
    );
    const source = `OpenBurnBar-${VERSION}-corresponding-source.tar.gz`;
    const required = new Set([
      `OpenBurnBar-${VERSION}-macOS.dmg`,
      `OpenBurnBar-${VERSION}-macOS.zip`,
      source,
      `${source}.sha256`,
      "appcast.xml",
      "latest-macos.json",
      `checksums-v${VERSION}.txt`,
      "release-metadata.json",
    ]);
    const receiptPath = join(files.root, "rollback-target-receipt.json");
    writeFileSync(
      receiptPath,
      `${JSON.stringify(
        {
          schemaVersion: 1,
          kind: "macos-rollback-target",
          repository: REPOSITORY,
          tag: TAG,
          version: VERSION,
          commit: COMMIT,
          releaseIdentity: {
            releaseID: promotionReceipt.releaseIdentity.releaseID,
            assets: promotionReceipt.releaseIdentity.assets.filter((asset) =>
              required.has(asset.name),
            ),
          },
        },
        null,
        2,
      )}\n`,
    );
    const manifest = rollbackPreflight(
      files,
      join(files.assetDirectory, "appcast.xml"),
      receiptPath,
    );
    assert.equal(manifest.version, VERSION);
    assert.equal(
      manifest.verifyOnly[0].sha256,
      hash(files.assets.get(manifest.expected.dmg)),
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("rollback preflight rejects an appcast whose first item is not the target", () => {
  const files = fixture();
  try {
    const appcastPath = join(files.root, "appcast.xml");
    writeFileSync(
      appcastPath,
      readFileSync(join(files.assetDirectory, "appcast.xml"), "utf8").replace(
        `<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>`,
        "<sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>",
      ),
    );
    assert.throws(
      () => rollbackPreflight(files, appcastPath),
      /must exactly match the audited target release appcast/u,
    );
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("rollback public verification retries stale pointers and proves target payloads", async () => {
  const files = fixture();
  try {
    const manifest = rollbackPreflight(files);
    const entries = [
      ...manifest.groups.metadata,
      ...manifest.groups.discovery,
      ...manifest.verifyOnly,
    ];
    const bytesByName = new Map(
      entries.map((entry) => [entry.name, readFileSync(entry.path)]),
    );
    let staleServed = false;
    const result = await verifyPublicR2RollbackPublication(manifest, {
      attempts: 2,
      delayMs: 0,
      delayImpl: async () => {},
      verifyAppSignature: files.verifyAppSignature,
      fetchImpl: async (url) => {
        const name = decodeURIComponent(
          new URL(url).pathname.split("/").at(-1),
        );
        let bytes = bytesByName.get(name);
        assert(bytes, `unexpected rollback public asset request ${name}`);
        if (name === "appcast.xml" && !staleServed) {
          staleServed = true;
          bytes = Buffer.from("<rss>stale</rss>");
        }
        return new Response(bytes, {
          status: 200,
          headers: { "content-length": String(bytes.length) },
        });
      },
    });
    assert.equal(result.verified, true);
    assert.equal(result.attempts, 2);
    assert.equal(result.commit, COMMIT);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});

test("partial rollback publication restores the exact prior mutable pointer set", () => {
  const files = fixture();
  try {
    const state = join(files.root, "public-state");
    const bin = join(files.root, "bin");
    const wranglerLog = join(files.root, "wrangler.log");
    const putCount = join(files.root, "put-count");
    mkdirSync(state);
    mkdirSync(bin);
    const currentVersion = "8.8.8";
    const currentCommit = "b".repeat(40);
    const prior = new Map([
      ["release-metadata.json", Buffer.from('{"prior":"metadata"}\n')],
      [
        "latest-macos.json",
        Buffer.from(
          `${JSON.stringify({
            version: currentVersion,
            commit: currentCommit,
          })}\n`,
        ),
      ],
      ["appcast.xml", Buffer.from("<rss>prior-appcast</rss>\n")],
    ]);
    for (const [name, bytes] of prior) writeFileSync(join(state, name), bytes);

    const curl = join(bin, "curl");
    writeFileSync(
      curl,
      `#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --header) shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    --location|--show-error|--silent) shift ;;
    *) url="$1"; shift ;;
  esac
done
name="\${url%%\\?*}"
name="\${name##*/}"
path="$FAKE_R2_STATE/$name"
if [[ -f "$path" ]]; then
  cp "$path" "$output"
  printf '200'
else
  printf '404'
fi
`,
    );
    chmodSync(curl, 0o755);

    const wrangler = join(bin, "wrangler");
    writeFileSync(
      wrangler,
      `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$WRANGLER_LOG"
operation="$3"
target="$4"
name="\${target#*/}"
if [[ "$operation" == "put" ]]; then
  count=0
  [[ ! -f "$WRANGLER_PUT_COUNT" ]] || count="$(<"$WRANGLER_PUT_COUNT")"
  count=$((count + 1))
  printf '%s\\n' "$count" >"$WRANGLER_PUT_COUNT"
  if [[ "$count" == "2" ]]; then
    exit 42
  fi
  file=""
  shift 4
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--file" ]]; then file="$2"; break; fi
    shift
  done
  cp "$file" "$FAKE_R2_STATE/$name"
elif [[ "$operation" == "delete" ]]; then
  rm -f "$FAKE_R2_STATE/$name"
fi
`,
    );
    chmodSync(wrangler, 0o755);

    const result = spawnSync(
      "bash",
      ["scripts/publish-macos-appcast-rollback-r2.sh"],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          FAKE_R2_STATE: state,
          OPENBURNBAR_EXPECTED_LIVE_COMMIT: currentCommit,
          OPENBURNBAR_EXPECTED_LIVE_VERSION: currentVersion,
          OPENBURNBAR_RELEASE_ASSET_DIR: files.assetDirectory,
          OPENBURNBAR_RELEASE_COMMIT: COMMIT,
          OPENBURNBAR_RELEASE_RECEIPT: files.receiptPath,
          OPENBURNBAR_RELEASE_TAG: TAG,
          OPENBURNBAR_RELEASE_VERSION: VERSION,
          OPENBURNBAR_ROLLBACK_APPCAST: join(
            files.assetDirectory,
            "appcast.xml",
          ),
          OPENBURNBAR_ROLLBACK_CONFIRM: "publish-appcast-rollback",
          OPENBURNBAR_R2_CURL_BIN: curl,
          OPENBURNBAR_R2_PUBLIC_BASE_URL: PUBLIC_BASE_URL,
          OPENBURNBAR_TEST_CODESIGN_VERIFY_BIN: files.signatureVerifierPath,
          OPENBURNBAR_VERIFY_ATTEMPTS: "1",
          OPENBURNBAR_VERIFY_DELAY_MS: "0",
          NODE_ENV: "test",
          NODE_TEST_CONTEXT: process.env.NODE_TEST_CONTEXT ?? "child-v8",
          WRANGLER_BIN: wrangler,
          WRANGLER_LOG: wranglerLog,
          WRANGLER_PUT_COUNT: putCount,
        },
      },
    );
    assert.notEqual(result.status, 0);
    for (const [name, bytes] of prior) {
      assert.deepEqual(readFileSync(join(state, name)), bytes);
    }
    assert.match(readFileSync(wranglerLog, "utf8"), /release-metadata\.json/u);
  } finally {
    rmSync(files.root, { recursive: true, force: true });
  }
});
