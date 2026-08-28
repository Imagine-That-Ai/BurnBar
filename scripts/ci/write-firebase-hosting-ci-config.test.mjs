#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const generator = resolve(
  repoRoot,
  "scripts/ci/write-firebase-hosting-ci-config.mjs",
);

function generate(args) {
  return spawnSync(process.execPath, [generator, ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
}

const firebaseJsonPath = resolve(repoRoot, "firebase.json");

function readFirebaseJson() {
  return JSON.parse(readFileSync(firebaseJsonPath, "utf8"));
}

function hostingEntry(target) {
  const entry = readFirebaseJson().hosting.find(
    (candidate) => candidate.target === target,
  );
  assert.ok(entry, `firebase.json is missing hosting target ${target}`);
  return entry;
}

// Runs the generator against a mutated copy of the committed firebase.json.
// The source is written outside the repo so a failing assertion can never leave
// a corrupted firebase.json behind.
function generateFromMutatedSource(mutate, extraArgs = []) {
  const directory = mkdtempSync(join(tmpdir(), "firebase-ci-config-mutated-"));
  try {
    const firebaseJson = readFirebaseJson();
    mutate(firebaseJson);
    const source = join(directory, "firebase.json");
    writeFileSync(source, `${JSON.stringify(firebaseJson, null, 2)}\n`);
    const output = join(directory, "firebase-hosting.ci.json");
    const result = generate([
      "--source",
      source,
      "--output",
      output,
      ...extraArgs,
    ]);
    const config =
      result.status === 0
        ? JSON.parse(readFileSync(output, "utf8"))
        : undefined;
    return { result, config };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("portable Functions config resolves inside a distinct deploy artifact root", () => {
  const root = mkdtempSync(
    join(realpathSync(tmpdir()), "obb-functions-config-"),
  );
  try {
    const deployRoot = join(root, "deploy-runner", "prepared-artifact");
    mkdirSync(join(deployRoot, "functions"), { recursive: true });
    const output = join(deployRoot, "firebase-functions.ci.json");
    const result = generate([
      "--mode",
      "functions",
      "--output",
      output,
      "--portable-functions-source",
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr || result.stdout);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(config.functions.source, "functions");
    assert.equal(
      resolve(dirname(output), config.functions.source),
      join(deployRoot, "functions"),
    );
    assert.notEqual(
      resolve(dirname(output), config.functions.source),
      resolve(dirname(generator), "../..", "functions"),
    );
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});

test("portable Functions config fails when the staged source is absent", () => {
  const root = mkdtempSync(
    join(realpathSync(tmpdir()), "obb-functions-config-"),
  );
  try {
    const output = join(root, "firebase-functions.ci.json");
    const result = generate([
      "--mode",
      "functions",
      "--output",
      output,
      "--portable-functions-source",
      "--check",
    ]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /does not resolve beside the output config/u);
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});

test("firestore mode binds an explicit staging bucket without default discovery", () => {
  const directory = mkdtempSync(join(tmpdir(), "firebase-ci-config-"));
  try {
    const output = join(directory, "firebase-firestore.ci.json");
    const bucket = "burnbar-staging.firebasestorage.app";
    const result = generate([
      "--mode",
      "firestore",
      "--storage-bucket",
      bucket,
      "--output",
      output,
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.ok(Array.isArray(config.storage));
    assert.equal(config.storage.length, 1);
    assert.equal(config.storage[0].bucket, bucket);
    assert.ok(config.storage[0].rules.endsWith("/storage.rules"));
    assert.equal(JSON.stringify(config).includes("predeploy"), false);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("firestore mode preserves production object form without an explicit bucket", () => {
  const directory = mkdtempSync(join(tmpdir(), "firebase-ci-config-"));
  try {
    const output = join(directory, "firebase-firestore.ci.json");
    const result = generate([
      "--mode",
      "firestore",
      "--output",
      output,
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(Array.isArray(config.storage), false);
    assert.equal(config.storage.bucket, undefined);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("explicit bucket names fail closed on invalid input", () => {
  const result = generate([
    "--mode",
    "firestore",
    "--storage-bucket",
    "https://Invalid/Bucket",
    "--output",
    join(tmpdir(), "must-not-write-firebase-config.json"),
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /valid lowercase Cloud Storage bucket name/);
});

test("staging hosting preserves a reviewed collector connect-src from --source", () => {
  const collectorOrigin = "https://collector.example";
  const { result, config } = generateFromMutatedSource((firebaseJson) => {
    const marketing = firebaseJson.hosting.find(
      (entry) => entry.target === "marketing",
    );
    assert.ok(marketing, "mutated source must keep the marketing target");
    const csp = marketing.headers
      ?.flatMap((entry) => entry.headers ?? [])
      .find((header) => header.key === "Content-Security-Policy");
    assert.ok(csp, "mutated source must keep a marketing CSP");
    csp.value = csp.value.replace(
      "connect-src 'self'",
      `connect-src 'self' ${collectorOrigin}`,
    );
  }, ["--mode", "staging-hosting", "--check"]);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const csp = config.hosting[0].headers
    .flatMap((entry) => entry.headers ?? [])
    .find((header) => header.key === "Content-Security-Policy");
  assert.match(csp.value, /connect-src 'self' https:\/\/collector\.example/);
});

test("staging hosting emits only the marketing site with a noindex boundary", () => {
  const directory = mkdtempSync(join(tmpdir(), "firebase-staging-hosting-"));
  try {
    const output = join(directory, "firebase-hosting.staging.json");
    const manifest = join(directory, "firebase-hosting.staging.manifest.json");
    const result = generate([
      "--mode",
      "staging-hosting",
      "--output",
      output,
      "--manifest",
      manifest,
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr || result.stdout);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(config.hosting.length, 1);
    assert.equal(config.hosting[0].target, undefined);
    assert.equal(config.hosting[0].site, "burnbar-staging");
    assert.equal(config.hosting[0].public, "website/dist");
    assert.equal(JSON.stringify(config).includes("predeploy"), false);
    assert.ok(
      config.hosting[0].headers.some(
        (entry) =>
          entry.source === "**" &&
          entry.headers.some(
            (header) =>
              header.key === "X-Robots-Tag" &&
              header.value === "noindex, nofollow, noarchive",
          ),
      ),
    );

    const generatedManifest = JSON.parse(readFileSync(manifest, "utf8"));
    assert.deepEqual(generatedManifest.hostingPublicDirs, {
      marketing: "website/dist",
    });
    assert.equal(generatedManifest.project, "burnbar-staging");
    assert.equal(generatedManifest.noindex, true);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

// The committed firebase.json is the input both production deploy lanes run
// against. Before this coverage existed, adding the arena-artifacts target made
// the generator throw for --mode hosting AND --mode staging-hosting, which does
// not fail a PR — it fails production hosting deploys after merge, and keeps
// failing. These two tests assert against the real committed file for exactly
// that reason.
test("committed firebase.json generates a production hosting config", () => {
  const directory = mkdtempSync(join(tmpdir(), "firebase-committed-hosting-"));
  try {
    const output = join(directory, "firebase-hosting.ci.json");
    const manifest = join(directory, "firebase-hosting-public-dirs.json");
    const result = generate([
      "--mode",
      "hosting",
      "--output",
      output,
      "--manifest",
      manifest,
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr || result.stdout);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.deepEqual(
      config.hosting.map((entry) => [entry.target, entry.public]),
      [
        ["marketing", "website/dist"],
        ["console", "apps/console/out"],
      ],
    );
    // Mirrors the independent python guard in deploy-hosting.yml so a drift
    // between the two shows up here instead of mid-deploy.
    assert.deepEqual(Object.keys(config), ["hosting"]);
    assert.deepEqual(JSON.parse(readFileSync(manifest, "utf8")), {
      hostingPublicDirs: {
        marketing: "website/dist",
        console: "apps/console/out",
      },
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("committed firebase.json generates a staging hosting config", () => {
  const directory = mkdtempSync(join(tmpdir(), "firebase-committed-staging-"));
  try {
    const output = join(directory, "firebase-hosting.staging.json");
    const result = generate([
      "--mode",
      "staging-hosting",
      "--output",
      output,
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr || result.stdout);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(config.hosting.length, 1);
    assert.equal(config.hosting[0].site, "burnbar-staging");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("arena-artifacts is recognised but never emitted into a CI deploy config", () => {
  // arena-public is hand-deployed on purpose: the CI deployer
  // (scripts/ci/deploy-firebase-hosting-rest.mjs) uploads every file under the
  // public dir and never reads `ignore`, and the bundle tree is gitignored, so
  // a CI deploy would both bypass the publish allowlist and overwrite the live
  // site with the one file a checkout actually contains.
  assert.equal(hostingEntry("arena-artifacts").public, "arena-public");

  for (const mode of ["hosting", "staging-hosting"]) {
    const directory = mkdtempSync(join(tmpdir(), "firebase-arena-excluded-"));
    try {
      const output = join(directory, "config.json");
      const result = generate(["--mode", mode, "--output", output, "--check"]);
      assert.equal(result.status, 0, result.stderr || result.stdout);
      const config = JSON.parse(readFileSync(output, "utf8"));
      // Identity fields only: the marketing CSP legitimately names the
      // arena-artifacts origin as a frame-src, so a raw substring scan would
      // match that instead of an actual deployable entry.
      const identities = config.hosting.flatMap((entry) => [
        entry.target,
        entry.site,
        entry.public,
      ]);
      assert.equal(
        identities.some(
          (value) => typeof value === "string" && value.includes("arena"),
        ),
        false,
        `${mode} config leaked an arena target: ${JSON.stringify(identities)}`,
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }
});

test("the CI-deployable allowlist still fails closed on an unknown target", () => {
  const { result } = generateFromMutatedSource((firebaseJson) => {
    firebaseJson.hosting.push({
      target: "exfiltration",
      public: "website/dist",
      ignore: ["firebase.json"],
    });
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unexpected hosting target exfiltration/u);
});

test("a CI-excluded target cannot be repointed at another public dir", () => {
  const { result } = generateFromMutatedSource((firebaseJson) => {
    const entry = firebaseJson.hosting.find(
      (candidate) => candidate.target === "arena-artifacts",
    );
    entry.public = "website/dist";
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /arena-artifacts public dir drifted/u);
});

// The three files below map every matchup_id to the exact harness/model that
// produced each side. Publishing any of them lets a voter read off the answer
// before voting, which invalidates the ratings those votes produce.
const ARENA_DEANONYMISATION_KEY = [
  "arena_matchups.jsonl",
  "seed_docs.json",
  "publish_manifest.json",
];

test("arena-artifacts publishes via an allowlist, not a denylist", () => {
  const ignore = hostingEntry("arena-artifacts").ignore;

  // Deny-by-default: every top-level entry that is not index.html or bundles is
  // ignored, and so is its subtree. A newly generated file therefore stays
  // unpublished until someone deliberately re-admits it here.
  assert.ok(
    ignore.includes("!(index.html|bundles)"),
    `missing top-level deny-by-default pattern: ${JSON.stringify(ignore)}`,
  );
  assert.ok(
    ignore.includes("!(index.html|bundles)/**"),
    `missing subtree deny-by-default pattern: ${JSON.stringify(ignore)}`,
  );
  // "!(bundles)/**" would also drop index.html, because a glob "X/**" ignore
  // drops X itself. Guard against someone "simplifying" it back to that.
  assert.equal(
    ignore.some((pattern) => /^!\((?!index\.html\|)/u.test(pattern)),
    false,
    `deny-by-default pattern omits index.html: ${JSON.stringify(ignore)}`,
  );
  // Defence in depth: still denied by literal name if the matcher lacks extglob.
  for (const name of ARENA_DEANONYMISATION_KEY) {
    assert.ok(
      ignore.includes(name),
      `arena-artifacts ignore is missing ${name}: ${JSON.stringify(ignore)}`,
    );
  }
});

test("loosening the arena-artifacts publish allowlist fails the gate", () => {
  for (const mutation of [
    // Dropping deny-by-default back to a denylist.
    (entry) => {
      entry.ignore = entry.ignore.filter(
        (pattern) => !pattern.startsWith("!("),
      );
    },
    // Removing a single de-anonymisation-key deny entry.
    (entry) => {
      entry.ignore = entry.ignore.filter(
        (pattern) => pattern !== "seed_docs.json",
      );
    },
    // Re-admitting an extra top-level path.
    (entry) => {
      entry.ignore = entry.ignore.map((pattern) =>
        pattern.startsWith("!(")
          ? pattern.replace("!(index.html|bundles", "!(index.html|bundles|data")
          : pattern,
      );
    },
  ]) {
    const { result } = generateFromMutatedSource((firebaseJson) => {
      mutation(
        firebaseJson.hosting.find(
          (candidate) => candidate.target === "arena-artifacts",
        ),
      );
    });
    assert.notEqual(result.status, 0);
    assert.match(
      result.stderr,
      /arena-artifacts ignore list drifted from the reviewed publish allowlist/u,
    );
  }
});
