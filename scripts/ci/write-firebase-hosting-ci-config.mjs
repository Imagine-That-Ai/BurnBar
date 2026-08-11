#!/usr/bin/env node
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);

let sourcePath = resolve(repoRoot, "firebase.json");
let outputPath = resolve(repoRoot, "firebase-hosting.ci.json");
let manifestPath = "";
let storageBucket = "";
let mode = "hosting";
let check = false;
let portableFunctionsSource = false;

function usage() {
  console.error(
    [
      "Usage: node scripts/ci/write-firebase-hosting-ci-config.mjs [options]",
      "",
      "Options:",
      "  --source <path>     Firebase config to read (default: firebase.json)",
      "  --output <path>     CI config to write (default: firebase-hosting.ci.json)",
      "  --manifest <path>   Public-dir manifest path for hosting mode",
      "  --storage-bucket <name>  Explicit bucket for firestore mode",
      "  --mode <mode>       hosting | staging-hosting | functions | firestore (default: hosting)",
      '  --portable-functions-source  Emit artifact-relative functions.source="functions"',
      "  --check             Verify the generated config contains no predeploy hooks",
    ].join("\n"),
  );
}

for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === "--source") {
    sourcePath = resolve(repoRoot, args[++index] ?? "");
  } else if (arg === "--output") {
    outputPath = resolve(repoRoot, args[++index] ?? "");
  } else if (arg === "--manifest") {
    manifestPath = resolve(repoRoot, args[++index] ?? "");
  } else if (arg === "--storage-bucket") {
    storageBucket = args[++index] ?? "";
  } else if (arg === "--mode") {
    mode = args[++index] ?? "";
  } else if (arg === "--check") {
    check = true;
  } else if (arg === "--portable-functions-source") {
    portableFunctionsSource = true;
  } else if (arg === "--help" || arg === "-h") {
    usage();
    process.exit(0);
  } else {
    throw new Error(`Unknown argument: ${arg}`);
  }
}

const supportedModes = new Set([
  "hosting",
  "staging-hosting",
  "functions",
  "firestore",
]);
if (!supportedModes.has(mode)) {
  throw new Error(
    `Unsupported mode ${mode}; expected one of ${[...supportedModes].join(", ")}`,
  );
}
if (portableFunctionsSource && mode !== "functions") {
  throw new Error("--portable-functions-source requires --mode functions");
}
if (storageBucket) {
  if (mode !== "firestore") {
    throw new Error("--storage-bucket is supported only in firestore mode");
  }
  if (
    storageBucket.length < 3 ||
    storageBucket.length > 222 ||
    !/^[a-z0-9][a-z0-9._-]*[a-z0-9]$/.test(storageBucket)
  ) {
    throw new Error(
      "--storage-bucket must be a valid lowercase Cloud Storage bucket name",
    );
  }
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Failed to parse ${path}: ${error.message}`);
  }
}

function assertNoPredeploy(value, label) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) =>
      assertNoPredeploy(entry, `${label}[${index}]`),
    );
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (key === "predeploy") {
      throw new Error(`${label} still contains a predeploy hook`);
    }
    assertNoPredeploy(child, `${label}.${key}`);
  }
}

function requirePlainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function copyDefined(source, keys) {
  const result = {};
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(source, key)) {
      result[key] = source[key];
    }
  }
  return result;
}

function resolveRepoFilePath(value, label) {
  if (
    typeof value !== "string" ||
    value.trim() !== value ||
    value.length === 0
  ) {
    throw new Error(`${label} must be a non-empty trimmed path`);
  }
  const resolved = resolve(repoRoot, value);
  if (!existsSync(resolved) || !statSync(resolved).isFile()) {
    throw new Error(`${label} does not resolve to a file: ${resolved}`);
  }
  return resolved;
}

function resolveRepoDirectoryPath(value, label) {
  if (
    typeof value !== "string" ||
    value.trim() !== value ||
    value.length === 0
  ) {
    throw new Error(`${label} must be a non-empty trimmed path`);
  }
  const resolved = resolve(repoRoot, value);
  if (!existsSync(resolved) || !statSync(resolved).isDirectory()) {
    throw new Error(`${label} does not resolve to a directory: ${resolved}`);
  }
  return resolved;
}

function buildHostingConfig(firebaseJson) {
  const hosting = firebaseJson.hosting;
  if (!Array.isArray(hosting)) {
    throw new Error(
      "firebase.json hosting must be an array for CI hosting deploys",
    );
  }

  // Hosting targets the credentialed CI deploy lane is permitted to publish.
  // This is a security control, not a schema: the WIF/OIDC service account that
  // runs the production hosting deploy can push bytes to any site named here,
  // so an addition to this map is a decision about what CI may put on the
  // public internet.
  const expectedPublicDirs = new Map([
    ["marketing", "website/dist"],
    ["console", "apps/console/out"],
  ]);

  // Hosting targets that exist in firebase.json but are deliberately OUTSIDE
  // the CI deploy lane. They are recognised (so the allowlist above keeps its
  // fail-closed property for genuinely unknown targets) and then dropped from
  // the generated config, so CI never deploys them.
  //
  // arena-artifacts / arena-public: deployed BY HAND, and it must stay that
  // way. Three independent reasons, each sufficient on its own:
  //
  //   1. The CI deployer does not honour `ignore`. scripts/ci/deploy-firebase-
  //      hosting-rest.mjs listFiles() walks the public dir and uploads every
  //      regular file it finds; it never reads the hosting entry's `ignore`
  //      array. The allowlist-shaped ignore that keeps arena_matchups.jsonl,
  //      seed_docs.json and publish_manifest.json off the site is enforced by
  //      the firebase-tools matcher on the hand-deploy path only. Admitting
  //      arena-artifacts here would therefore publish the arena's
  //      de-anonymisation key on every push to main, with the protection
  //      silently bypassed.
  //
  //   2. CI has no source for the content. arena-public/bundles/ and the three
  //      key files are gitignored (this repo is public), so a CI checkout
  //      contains only arena-public/index.html. A CI deploy would replace the
  //      ~3.9k hand-published files with a single page — a destructive
  //      "successful" deploy.
  //
  //   3. The directory's whole purpose is blind-comparison material. Widening a
  //      credentialed-lane allowlist to cover it is the wrong direction on a
  //      control whose entire job is limiting what CI may publish.
  //
  // The public dir is still pinned below, so a rename or repoint of the
  // arena-artifacts target fails this gate instead of drifting unobserved.
  const ciExcludedPublicDirs = new Map([["arena-artifacts", "arena-public"]]);

  // The reviewed allowlist-shaped `ignore` for arena-artifacts, pinned so it
  // cannot be quietly loosened back into a denylist.
  //
  // arena-public/ is a regenerated deploy staging tree, not a curated web root:
  // the arena publisher drops new top-level files there whenever the bench
  // pipeline changes. Under a denylist ("deny these three names") the next
  // generated file is published by default — and because the arena is a BLIND
  // pairwise comparison whose votes produce published model ratings, one leaked
  // index file does not merely leak data, it invalidates every rating those
  // votes produce. So the list denies everything and re-admits exactly
  // index.html and bundles/**.
  //
  // Verified against the pinned firebase-tools matcher (lib/listFiles.js ->
  // glob.sync("**\/*", { ignore })):
  //   "!(index.html|bundles)"    ignores every top-level entry that is not one
  //                              of the two admitted names.
  //   "!(index.html|bundles)/**" ignores those entries' subtrees. In glob v10 an
  //                              "X/**" ignore also drops X itself, so the
  //                              admitted names must be repeated here; the
  //                              shorter "!(bundles)/**" silently drops
  //                              index.html as well.
  // Naive negation ("**" plus "!bundles/**") publishes ZERO files — glob's
  // ignore is a pure OR of deny patterns with no re-admit semantics.
  //
  // The three literal filenames are defence in depth: they keep the
  // de-anonymisation key denied even under a matcher without extglob support.
  // Measured on the real tree: 3874 files published before (all three key files
  // among them), 3871 after, zero key files.
  const arenaArtifactsIgnore = [
    "firebase.json",
    "**/.*",
    "**/node_modules/**",
    "!(index.html|bundles)",
    "!(index.html|bundles)/**",
    "arena_matchups.jsonl",
    "seed_docs.json",
    "publish_manifest.json",
  ];
  const pinnedIgnoreLists = new Map([
    ["arena-artifacts", arenaArtifactsIgnore],
  ]);

  const allowedHostingKeys = new Set([
    "target",
    "public",
    "ignore",
    "headers",
    "redirects",
    "rewrites",
    "cleanUrls",
    "trailingSlash",
    "i18n",
    "predeploy",
  ]);
  const preservedKeys = [
    "target",
    "public",
    "ignore",
    "headers",
    "redirects",
    "rewrites",
    "cleanUrls",
    "trailingSlash",
    "i18n",
  ];

  const seenTargets = new Set();
  const ciHosting = [];

  for (const entry of hosting) {
    requirePlainObject(entry, "hosting entry");
    for (const key of Object.keys(entry)) {
      if (!allowedHostingKeys.has(key)) {
        throw new Error(
          `hosting target ${entry.target ?? "<missing>"} has unsupported key ${key}`,
        );
      }
    }

    const target = entry.target;
    const ciDeployable = expectedPublicDirs.has(target);
    const ciExcluded = ciExcludedPublicDirs.has(target);
    if (!ciDeployable && !ciExcluded) {
      throw new Error(`unexpected hosting target ${target ?? "<missing>"}`);
    }
    if (seenTargets.has(target)) {
      throw new Error(`duplicate hosting target ${target}`);
    }
    seenTargets.add(target);

    const expectedPublic = ciDeployable
      ? expectedPublicDirs.get(target)
      : ciExcludedPublicDirs.get(target);
    if (entry.public !== expectedPublic) {
      throw new Error(
        `hosting target ${target} public dir drifted: ${entry.public ?? "<missing>"} != ${expectedPublic}`,
      );
    }

    const pinnedIgnore = pinnedIgnoreLists.get(target);
    if (
      pinnedIgnore &&
      JSON.stringify(entry.ignore) !== JSON.stringify(pinnedIgnore)
    ) {
      throw new Error(
        `hosting target ${target} ignore list drifted from the reviewed publish allowlist: ${JSON.stringify(entry.ignore ?? null)} != ${JSON.stringify(pinnedIgnore)}`,
      );
    }

    if (ciExcluded) {
      // Recognised, validated, and then deliberately not emitted: the CI deploy
      // lane must never see this target. See ciExcludedPublicDirs above.
      continue;
    }

    ciHosting.push(copyDefined(entry, preservedKeys));
  }

  for (const target of expectedPublicDirs.keys()) {
    if (!seenTargets.has(target)) {
      throw new Error(`missing hosting target ${target}`);
    }
  }

  const config = { hosting: ciHosting };
  assertNoPredeploy(config, "firebase-hosting.ci.json");
  return {
    config,
    manifest: {
      hostingPublicDirs: Object.fromEntries(expectedPublicDirs.entries()),
    },
  };
}

function buildStagingHostingConfig(firebaseJson) {
  const generated = buildHostingConfig(firebaseJson);
  const productionMarketing = generated.config.hosting.find(
    (entry) => entry.target === "marketing",
  );
  if (!productionMarketing) {
    throw new Error(
      "production hosting config is missing the marketing target",
    );
  }

  const marketing = structuredClone(productionMarketing);
  delete marketing.target;
  marketing.site = "burnbar-staging";
  const globalHeaders = marketing.headers?.find(
    (entry) => entry.source === "**",
  );
  if (!globalHeaders || !Array.isArray(globalHeaders.headers)) {
    throw new Error(
      "marketing hosting config must contain a global headers entry",
    );
  }
  globalHeaders.headers = globalHeaders.headers.filter(
    (header) => header.key.toLowerCase() !== "x-robots-tag",
  );
  globalHeaders.headers.push({
    key: "X-Robots-Tag",
    value: "noindex, nofollow, noarchive",
  });

  const config = { hosting: [marketing] };
  assertNoPredeploy(config, "firebase-hosting.staging.json");
  return {
    config,
    manifest: {
      hostingPublicDirs: { marketing: "website/dist" },
      project: "burnbar-staging",
      noindex: true,
    },
  };
}

function buildFunctionsConfig(firebaseJson) {
  const functions = requirePlainObject(
    firebaseJson.functions,
    "firebase.json functions",
  );
  const allowedKeys = new Set([
    "source",
    "runtime",
    "ignore",
    "codebase",
    "predeploy",
  ]);
  for (const key of Object.keys(functions)) {
    if (!allowedKeys.has(key)) {
      throw new Error(`functions config has unsupported key ${key}`);
    }
  }
  const config = {
    functions: copyDefined(functions, [
      "source",
      "runtime",
      "ignore",
      "codebase",
    ]),
  };
  if (config.functions.source !== undefined) {
    const absoluteSource = resolveRepoDirectoryPath(
      config.functions.source,
      "functions.source",
    );
    if (portableFunctionsSource) {
      if (config.functions.source !== "functions") {
        throw new Error(
          '--portable-functions-source requires canonical functions.source="functions"',
        );
      }
      const stagedSource = resolve(dirname(outputPath), "functions");
      if (!existsSync(stagedSource) || !statSync(stagedSource).isDirectory()) {
        throw new Error(
          `portable functions.source does not resolve beside the output config: ${stagedSource}`,
        );
      }
      config.functions.source = "functions";
    } else {
      config.functions.source = absoluteSource;
    }
  }
  assertNoPredeploy(config, "firebase-functions.ci.json");
  return { config, manifest: { functionsSource: config.functions.source } };
}

function buildFirestoreConfig(firebaseJson) {
  const config = {};
  if (firebaseJson.firestore !== undefined) {
    const firestore = requirePlainObject(
      firebaseJson.firestore,
      "firebase.json firestore",
    );
    config.firestore = { ...firestore };
    if (config.firestore.rules !== undefined) {
      config.firestore.rules = resolveRepoFilePath(
        config.firestore.rules,
        "firestore.rules",
      );
    }
    if (config.firestore.indexes !== undefined) {
      config.firestore.indexes = resolveRepoFilePath(
        config.firestore.indexes,
        "firestore.indexes",
      );
    }
  }
  if (firebaseJson.storage !== undefined) {
    const storage = requirePlainObject(
      firebaseJson.storage,
      "firebase.json storage",
    );
    const storageConfig = { ...storage };
    if (storageConfig.rules !== undefined) {
      storageConfig.rules = resolveRepoFilePath(
        storageConfig.rules,
        "storage.rules",
      );
    }
    // Firebase CLI looks up a project's default bucket only for object-form
    // storage config. Staging binds the already-provisioned bucket explicitly
    // so deploys do not depend on eventually-consistent control-plane discovery.
    config.storage = storageBucket
      ? [{ ...storageConfig, bucket: storageBucket }]
      : storageConfig;
  }
  if (!config.firestore && !config.storage) {
    throw new Error(
      "firebase.json must contain firestore or storage config for firestore mode",
    );
  }
  assertNoPredeploy(config, "firebase-firestore.ci.json");
  const generatedStorage = Array.isArray(config.storage)
    ? config.storage[0]
    : config.storage;
  return {
    config,
    manifest: {
      firestoreRules: config.firestore?.rules,
      firestoreIndexes: config.firestore?.indexes,
      storageRules: generatedStorage?.rules,
      storageBucket: generatedStorage?.bucket,
    },
  };
}

const firebaseJson = readJson(sourcePath);
const builders = {
  hosting: buildHostingConfig,
  "staging-hosting": buildStagingHostingConfig,
  functions: buildFunctionsConfig,
  firestore: buildFirestoreConfig,
};
const { config, manifest } = builders[mode](firebaseJson);
assertNoPredeploy(config, outputPath);

writeFileSync(outputPath, `${JSON.stringify(config, null, 2)}\n`);
if (manifestPath) {
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

if (check) {
  const generated = readJson(outputPath);
  assertNoPredeploy(generated, outputPath);
}

console.log(
  `Wrote ${mode} Firebase CI config without predeploy hooks: ${outputPath}`,
);
if (manifestPath) {
  console.log(`Wrote ${mode} Firebase CI manifest: ${manifestPath}`);
}
