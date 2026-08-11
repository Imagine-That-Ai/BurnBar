#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "../..");
const DEPLOYER = join(SCRIPT_DIR, "deploy-firebase-hosting-rest.mjs");
const CONFIG_WRITER = join(SCRIPT_DIR, "write-firebase-hosting-ci-config.mjs");
const COMMITTED_FIREBASERC = join(REPO_ROOT, ".firebaserc");
const COMMITTED_FIREBASE_JSON = join(REPO_ROOT, "firebase.json");
const COMMITTED_ARENA_CONFIG = join(REPO_ROOT, "firebase.arena.json");

const roots = [];
process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function scratch(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  roots.push(root);
  return root;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

// `firebaserc` may be an object (fixture) or "committed" to copy the real
// repository file in. See the committed-.firebaserc tests below for why that
// distinction is the entire point of this file.
function makeArtifact(config, firebaserc = "fixture") {
  const root = scratch("hosting-rest-test-");
  mkdirSync(join(root, "website", "dist"), { recursive: true });
  mkdirSync(join(root, "apps", "console", "out"), { recursive: true });
  writeFileSync(
    join(root, "website", "dist", "index.html"),
    "<h1>BurnBar</h1>\n",
  );
  writeFileSync(
    join(root, "apps", "console", "out", "index.html"),
    "<h1>Console</h1>\n",
  );
  if (firebaserc === "committed") {
    copyFileSync(COMMITTED_FIREBASERC, join(root, ".firebaserc"));
  } else {
    writeFileSync(
      join(root, ".firebaserc"),
      JSON.stringify(
        firebaserc === "fixture"
          ? {
              projects: { default: "burnbar", staging: "burnbar-staging" },
              targets: {
                burnbar: {
                  hosting: {
                    marketing: ["burnbar"],
                    console: ["burnbar-console"],
                  },
                },
                "burnbar-staging": {
                  hosting: {
                    marketing: ["burnbar-staging"],
                    console: ["burnbar-staging-console"],
                  },
                },
              },
            }
          : firebaserc,
        null,
        2,
      ),
    );
  }
  writeFileSync(
    join(root, "firebase-hosting.ci.json"),
    JSON.stringify(config, null, 2),
  );
  return root;
}

function run(root, configName = "firebase-hosting.ci.json") {
  return execFileSync(
    "node",
    [
      DEPLOYER,
      "--project",
      "burnbar",
      "--config",
      join(root, configName),
      "--firebaserc",
      join(root, ".firebaserc"),
      "--dry-run",
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
}

function expectFailure(fn, needle, label) {
  let output = "";
  try {
    output = fn();
  } catch (error) {
    const stderr = error.stderr?.toString("utf8") ?? "";
    const stdout = error.stdout?.toString("utf8") ?? "";
    if (!stderr.includes(needle) && !stdout.includes(needle)) throw error;
    return;
  }
  throw new Error(`${label} unexpectedly passed:\n${output}`);
}

const goodConfig = {
  hosting: [
    {
      target: "marketing",
      public: "website/dist",
      cleanUrls: true,
      trailingSlash: false,
      headers: [{ source: "**", headers: [{ key: "X-Test", value: "ok" }] }],
      redirects: [
        { source: "/docs", destination: "https://example.com", type: 301 },
      ],
      rewrites: [
        {
          source: "/api/**",
          function: {
            functionId: "latestRouterRundown",
            region: "us-central1",
          },
        },
        { source: "**", destination: "/404.html" },
      ],
    },
    {
      target: "console",
      public: "apps/console/out",
      cleanUrls: true,
      trailingSlash: false,
    },
  ],
};

// ── Fixture coverage: config conversion and the target-map control ────────────

const output = run(makeArtifact(goodConfig));
if (!output.includes("hosting[burnbar] target=marketing files=1")) {
  throw new Error(`marketing target was not dry-run deployed:\n${output}`);
}
if (!output.includes("hosting[burnbar-console] target=console files=1")) {
  throw new Error(`console target was not dry-run deployed:\n${output}`);
}
if (!output.includes("DRY_RUN:")) {
  throw new Error(`dry-run summary missing:\n${output}`);
}

const badConfig = structuredClone(goodConfig);
badConfig.hosting[0].rewrites[0].function.pinTag = true;
expectFailure(
  () => run(makeArtifact(badConfig)),
  "pinTag",
  "pinned function rewrite",
);

const wrongTargetRoot = makeArtifact(goodConfig);
const wrongFirebaserc = join(wrongTargetRoot, ".firebaserc");
const wrongTargets = readJson(wrongFirebaserc);
wrongTargets.targets.burnbar.hosting.console = ["attacker-controlled-site"];
writeFileSync(wrongFirebaserc, JSON.stringify(wrongTargets));
expectFailure(
  () => run(wrongTargetRoot),
  "exact reviewed production and staging Hosting target maps",
  "mismatched production Hosting target",
);

// ── Committed-file coverage ──────────────────────────────────────────────────
//
// Everything above runs against a FIXTURE .firebaserc, so all of it passes
// while the real committed .firebaserc is unusable. That is not hypothetical:
// adding an `arena-artifacts` hosting alias to .firebaserc left this file
// green at 1/1 and broke the production hosting deploy at the target-map
// assertion — a failure that only surfaces after merge, in the credentialed
// deploy step, and then repeats on every subsequent push.
//
// The tests below therefore run the REAL committed .firebaserc through the
// REAL assertion, and the real firebase.json through the real CI config
// generator, so that class of break fails here instead.

const committedFirebaserc = readJson(COMMITTED_FIREBASERC);

// Read the committed map first and explain any drift in its own terms. The
// deployer's whole-object comparison below is the real gate, but it fails with a
// single opaque sentence; these checks run first so the common breakages arrive
// already diagnosed.
//
// The arena artifacts site is deliberately absent: with no alias it is
// unreachable from the credentialed CI lane even if a generated config named it.
for (const [project, entry] of Object.entries(
  committedFirebaserc.targets ?? {},
)) {
  for (const target of Object.keys(entry?.hosting ?? {})) {
    if (target === "marketing" || target === "console") continue;
    throw new Error(
      `committed .firebaserc project ${project} declares hosting target ${target}. ` +
        "Only marketing and console may be CI-deployable, and adding a target here " +
        "breaks every production hosting deploy at the reviewed target-map " +
        "assertion. The arena artifacts site is hand-deployed through " +
        "firebase.arena.json (site-addressed, no alias) precisely so CI cannot " +
        "publish it — see the comment above expectedHostingTargets in " +
        "deploy-firebase-hosting-rest.mjs.",
    );
  }
}

// Staging: deploy-staging-trusted.yml deploys a site-addressed config and never
// resolves an alias, but .firebaserc is a single shared file, so the deployer's
// whole-object assertion covers the staging half too. Pin it explicitly here so
// a staging-only edit fails with a message that names staging.
const committedStagingHosting =
  committedFirebaserc.targets?.["burnbar-staging"]?.hosting;
const expectedStagingHosting = {
  marketing: ["burnbar-staging"],
  console: ["burnbar-staging-console"],
};
if (
  JSON.stringify(committedStagingHosting) !==
  JSON.stringify(expectedStagingHosting)
) {
  throw new Error(
    `committed .firebaserc staging hosting map drifted from the reviewed map: ${JSON.stringify(
      committedStagingHosting ?? null,
    )} != ${JSON.stringify(expectedStagingHosting)}`,
  );
}

// Production: the committed .firebaserc must satisfy the deployer's reviewed
// target map, using the deployer's own assertion rather than a restatement.
let committedOutput = "";
try {
  committedOutput = run(makeArtifact(goodConfig, "committed"));
} catch (error) {
  const detail = `${error.stderr?.toString("utf8") ?? ""}${error.stdout?.toString("utf8") ?? ""}`;
  throw new Error(
    `the committed .firebaserc fails the production Hosting deploy assertion, so ` +
      `every deploy of deploy-hosting.yml would fail after merge:\n${detail}`,
  );
}
if (!committedOutput.includes("hosting[burnbar] target=marketing files=1")) {
  throw new Error(
    `committed .firebaserc did not resolve the marketing target:\n${committedOutput}`,
  );
}
if (
  !committedOutput.includes("hosting[burnbar-console] target=console files=1")
) {
  throw new Error(
    `committed .firebaserc did not resolve the console target:\n${committedOutput}`,
  );
}

// The control has to be live, not merely satisfied: re-adding the arena alias to
// the committed map must fail the deployer.
const arenaAliasFirebaserc = structuredClone(committedFirebaserc);
arenaAliasFirebaserc.targets.burnbar.hosting["arena-artifacts"] = [
  "burnbar-arena-artifacts",
];
expectFailure(
  () => run(makeArtifact(goodConfig, arenaAliasFirebaserc)),
  "exact reviewed production and staging Hosting target maps",
  "arena-artifacts hosting alias in .firebaserc",
);

// Production, end to end: the committed firebase.json through the real CI config
// generator, then that generated config plus the committed .firebaserc through
// the real deployer. This is the exact pair the credentialed deploy step runs.
const generatedRoot = makeArtifact(goodConfig, "committed");
execFileSync(
  "node",
  [
    CONFIG_WRITER,
    "--source",
    COMMITTED_FIREBASE_JSON,
    "--output",
    join(generatedRoot, "firebase-hosting.generated.json"),
    "--check",
  ],
  { encoding: "utf8", cwd: REPO_ROOT, stdio: ["ignore", "pipe", "pipe"] },
);
const generatedOutput = run(generatedRoot, "firebase-hosting.generated.json");
for (const expected of [
  "hosting[burnbar] target=marketing",
  "hosting[burnbar-console] target=console",
]) {
  if (!generatedOutput.includes(expected)) {
    throw new Error(
      `generated production config + committed .firebaserc did not produce "${expected}":\n${generatedOutput}`,
    );
  }
}
if (generatedOutput.includes("arena")) {
  throw new Error(
    `generated production config reached an arena site:\n${generatedOutput}`,
  );
}

// Staging, end to end: the committed firebase.json through the real staging
// generator. The result must be site-addressed, so the staging hosting deploy
// resolves no alias and cannot be broken by a .firebaserc target edit.
const stagingRoot = scratch("hosting-rest-staging-");
execFileSync(
  "node",
  [
    CONFIG_WRITER,
    "--source",
    COMMITTED_FIREBASE_JSON,
    "--mode",
    "staging-hosting",
    "--output",
    join(stagingRoot, "firebase-hosting.staging.json"),
    "--check",
  ],
  { encoding: "utf8", cwd: REPO_ROOT, stdio: ["ignore", "pipe", "pipe"] },
);
const stagingConfig = readJson(
  join(stagingRoot, "firebase-hosting.staging.json"),
);
for (const entry of stagingConfig.hosting) {
  if (entry.target !== undefined) {
    throw new Error(
      `staging hosting config is alias-addressed and would depend on .firebaserc: ${JSON.stringify(entry.target)}`,
    );
  }
  if (typeof entry.site !== "string" || !entry.site) {
    throw new Error(
      `staging hosting config entry is missing a site: ${JSON.stringify(entry)}`,
    );
  }
  if (entry.site.includes("arena") || entry.public.includes("arena")) {
    throw new Error(
      `staging hosting config reached an arena site: ${JSON.stringify(entry)}`,
    );
  }
}

// ── The hand-deploy config ───────────────────────────────────────────────────
//
// firebase.arena.json is how arena-public stays deployable at all now that the
// alias is gone. It is a verbatim copy of the reviewed arena-artifacts entry in
// firebase.json with `target` swapped for `site`, so the reviewed definition
// stays single-sourced and the gates in write-firebase-hosting-ci-config.mjs
// keep applying to it transitively. These assertions are what make "verbatim"
// true rather than aspirational.

const arenaConfig = readJson(COMMITTED_ARENA_CONFIG);
if (!Array.isArray(arenaConfig.hosting) || arenaConfig.hosting.length !== 1) {
  throw new Error(
    "firebase.arena.json must contain exactly one hosting entry; it exists only to hand-deploy the arena artifacts site",
  );
}
const arenaEntry = arenaConfig.hosting[0];
if (arenaEntry.site !== "burnbar-arena-artifacts") {
  throw new Error(
    `firebase.arena.json must address the arena site directly: ${JSON.stringify(arenaEntry.site ?? null)}`,
  );
}
if (arenaEntry.target !== undefined) {
  throw new Error(
    "firebase.arena.json must not use a hosting target alias: an alias would require a .firebaserc entry, which is exactly what keeps the arena site out of the CI lane",
  );
}

const reviewedArenaEntry = readJson(COMMITTED_FIREBASE_JSON).hosting.find(
  (entry) => entry.target === "arena-artifacts",
);
if (!reviewedArenaEntry) {
  throw new Error(
    "firebase.json is missing the reviewed arena-artifacts hosting entry that firebase.arena.json copies",
  );
}
const normalisedReviewed = { ...reviewedArenaEntry };
delete normalisedReviewed.target;
normalisedReviewed.site = "burnbar-arena-artifacts";
const normalisedHandDeploy = { ...arenaEntry };
for (const key of new Set([
  ...Object.keys(normalisedReviewed),
  ...Object.keys(normalisedHandDeploy),
])) {
  if (
    JSON.stringify(normalisedReviewed[key]) !==
    JSON.stringify(normalisedHandDeploy[key])
  ) {
    throw new Error(
      `firebase.arena.json drifted from the reviewed firebase.json arena-artifacts entry at ${key}: ` +
        `${JSON.stringify(normalisedHandDeploy[key] ?? null)} != ${JSON.stringify(normalisedReviewed[key] ?? null)}`,
    );
  }
}

// Self-contained restatement of the publish allowlist, so firebase.arena.json
// fails loudly on its own terms and not only by comparison. These three files
// map every matchup to the harness/model behind each side; publishing any of
// them lets a voter read off the answer, which invalidates the ratings those
// votes produce.
const arenaIgnore = arenaEntry.ignore;
for (const pattern of ["!(index.html|bundles)", "!(index.html|bundles)/**"]) {
  if (!arenaIgnore.includes(pattern)) {
    throw new Error(
      `firebase.arena.json ignore is missing deny-by-default pattern ${pattern}: ${JSON.stringify(arenaIgnore)}`,
    );
  }
}
// A glob "X/**" ignore drops X itself, so both admitted names must appear in the
// subtree pattern. "!(bundles)/**" would silently stop publishing index.html.
if (arenaIgnore.some((pattern) => /^!\((?!index\.html\|)/u.test(pattern))) {
  throw new Error(
    `firebase.arena.json deny-by-default pattern omits index.html: ${JSON.stringify(arenaIgnore)}`,
  );
}
for (const name of [
  "arena_matchups.jsonl",
  "seed_docs.json",
  "publish_manifest.json",
]) {
  if (!arenaIgnore.includes(name)) {
    throw new Error(
      `firebase.arena.json ignore is missing ${name}: ${JSON.stringify(arenaIgnore)}`,
    );
  }
}

// "Hand-deployed" has to stay true operationally, not just in a comment. No
// workflow may reference the hand-deploy config or the arena site selector: the
// whole design rests on the arena host having no automated path to production.
// Prose mentions in `#` comments are fine — that is where the reasoning lives.
const workflowsDir = join(REPO_ROOT, ".github", "workflows");
if (existsSync(workflowsDir)) {
  for (const name of readdirSync(workflowsDir)) {
    if (!name.endsWith(".yml") && !name.endsWith(".yaml")) continue;
    const lines = readFileSync(join(workflowsDir, name), "utf8").split("\n");
    lines.forEach((line, index) => {
      if (line.trimStart().startsWith("#")) return;
      for (const needle of [
        "firebase.arena.json",
        "hosting:burnbar-arena-artifacts",
      ]) {
        if (!line.includes(needle)) continue;
        throw new Error(
          `.github/workflows/${name}:${index + 1} references ${needle}. The arena ` +
            "artifacts site is hand-deployed out of band on purpose; automating it " +
            "would publish the site from a checkout that does not contain its " +
            "bundles, and would need credentials this lane deliberately lacks. If " +
            "this is intentional, change it here with the argument written down.",
        );
      }
    });
  }
}

// firebase-tools loads config through cjson, whose comment stripper tracks
// strings by hand and treats any quote preceded by a backslash as escaped. A
// backslash, a double quote, or a slash-star inside the "//" annotation
// desynchronises it and the whole file then fails to load — with an error
// pointing at an unrelated line. Keep the annotation boring.
const arenaAnnotation = arenaConfig["//"];
if (!Array.isArray(arenaAnnotation) || arenaAnnotation.length === 0) {
  throw new Error(
    'firebase.arena.json must keep its "//" annotation explaining why the arena host is hand-deployed',
  );
}
for (const line of arenaAnnotation) {
  if (
    typeof line !== "string" ||
    line.includes("\\") ||
    line.includes('"') ||
    line.includes("/*") ||
    line.includes("*/")
  ) {
    throw new Error(
      `firebase.arena.json annotation line breaks the cjson comment stripper: ${JSON.stringify(line)}`,
    );
  }
}

console.log(
  "PASS: Firebase Hosting REST deployer fixtures, the committed .firebaserc, and the arena hand-deploy config all check out.",
);
