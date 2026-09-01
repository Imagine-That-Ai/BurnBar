#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, appendFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// The workflow-level path filter used to be the Domain Core ownership policy.
// Keep that exact scope as candidate-controlled data now that every main push
// runs and this classifier selects the expensive proof lane.
const DOMAIN_CORE_PATH_POLICY = JSON.parse(
  readFileSync(
    new URL("../../config/domain-core-ci-paths.json", import.meta.url),
    "utf8",
  ),
);
if (
  DOMAIN_CORE_PATH_POLICY.schemaVersion !== 1 ||
  !Array.isArray(DOMAIN_CORE_PATH_POLICY.paths) ||
  DOMAIN_CORE_PATH_POLICY.paths.length === 0 ||
  new Set(DOMAIN_CORE_PATH_POLICY.paths).size !==
    DOMAIN_CORE_PATH_POLICY.paths.length ||
  DOMAIN_CORE_PATH_POLICY.paths.some(
    (path) =>
      typeof path !== "string" ||
      path.length === 0 ||
      path.startsWith("/") ||
      path.includes("\\") ||
      path.startsWith("!"),
  )
) {
  throw new Error("invalid Domain Core CI path policy");
}

export const DOMAIN_CORE_OWNED_PATH_GLOBS = Object.freeze([
  ...DOMAIN_CORE_PATH_POLICY.paths,
]);

export const LANES = [
  "macos",
  "mobile",
  "android",
  "rust",
  "daemon",
  "functions",
  "web",
  "console",
];

// Node Signal envelope contracts are consumed by Functions, hosted MCP, and
// Hermes relay. Fast Feedback already builds and tests this package. The
// catch-all npm FULL_PATTERNS below would otherwise treat its package.json /
// lockfile as a repo-wide graph change and wake every product lane, including
// a ~90 minute macos-26 libsignal FFI rebuild (BurnBar #2247, 2026-08-15).
// Only those two npm manifests take the exception. Source, tests, fixtures,
// and any other file under the package stay fail-closed.
const NODE_SIGNAL_ENVELOPE_CONTRACTS = Object.freeze([
  /^packages\/signal-envelope-contracts\/(?:package\.json|package-lock\.json)$/,
]);

// The Safari web extension is a self-contained npm project whose only product
// consumer is the macOS app bundle, which embeds its dist/ as the appex
// resources. Its two npm manifests would otherwise hit the repo-wide
// package.json rule above and wake every lane — including the ~90 minute
// macos-26 libsignal FFI rebuild — for a change that cannot reach them. Same
// false-full trap as the Signal envelope contracts above. Only the manifests
// take the exception; src, test, scripts, and configs stay fail-closed.
const SAFARI_EXTENSION_NPM_MANIFESTS = Object.freeze([
  /^extensions\/safari\/(?:package\.json|package-lock\.json)$/,
]);

// Android Gradle manifests match the catch-all `build.gradle(.kts)` /
// `settings.gradle(.kts)` / `gradle.properties` FULL_PATTERNS. Those filenames
// are fail-closed full when they sit at the repo root or in another ecosystem,
// but under `android/` they are the Android product graph only. Without this
// exemption an android-only Dependabot bump (BurnBar #2464) wakes Daemon PR
// Gate on macos-26 for a change that cannot reach the Swift daemon. Wrapper
// scripts, version catalogs, and Kotlin sources are already android-owned
// without hitting FULL_PATTERNS.
const ANDROID_GRADLE_MANIFESTS = Object.freeze([
  /^android\/(?:.*\/)?(?:build\.gradle(?:\.kts)?|settings\.gradle(?:\.kts)?|gradle\.properties)$/,
]);

// Paths that look repo-wide by filename but are provably lane-local. Every
// entry must ALSO be owned by a LANE_PATTERNS rule below, or it falls into
// `ambiguous` and fails closed to a full run regardless of this exemption.
const FULL_PATTERN_EXEMPTIONS = Object.freeze([
  ...NODE_SIGNAL_ENVELOPE_CONTRACTS,
  ...SAFARI_EXTENSION_NPM_MANIFESTS,
  ...ANDROID_GRADLE_MANIFESTS,
]);

const FULL_PATTERNS = [
  /(^|\/)(Package\.swift|Package\.resolved|Cargo\.toml|Cargo\.lock|build\.gradle(?:\.kts)?|settings\.gradle(?:\.kts)?|gradle\.properties|package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|[^/]+\.csproj|[^/]+\.slnx?|Directory\.Build\.(?:props|targets)|global\.json|packages\.lock\.json)$/,
  /^(OpenBurnBar\.xcodeproj|OpenBurnBar\.xcworkspace|tools\/schema-sync|Vendor\/|scripts\/lib\/|scripts\/release\/|scripts\/security\/)/,
  /^(governance\/|security\/|\.github\/CODEOWNERS|\.github\/dependabot\.yml)/,
  /^\.github\/workflows\/(?:burnbar-ci-gate|ci-impact|deploy-|release|security|codeql|dependency|secret|osv)/,
  /^scripts\/ci\/(?:classify-ci-impact|await-burnbar-ci-gate)/,
  /^config\/domain-core-ci-paths\.json$/,
  /^(firebase\.json|firestore\.|storage\.|apphosting\.|Dockerfile|Makefile|Brewfile)/,
];

const SAFE_NO_PRODUCT_PATTERNS = [
  /^(docs\/|droid-wiki\/|plans\/|\.github\/(?:ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE)|CHANGELOG\.md$|README\.md$|AGENTS\.md$|CLAUDE\.md$)/,
  /^launch-evidence\//,
  /^\.github\/workflows\//,
  /^(tests\/|scripts\/ci\/).*\.(?:py|mjs|js|sh|json|ya?ml)$/,
  /^windows\/tests\//,
];

const LANE_PATTERNS = {
  macos: [
    /^AgentLens\//,
    /^AgentLensTests\//,
    // The Safari appex and the web bundle it embeds are built by the macOS app
    // graph. Without these a PR touching only the extension selects no lane and
    // ships unbuilt — the path-filter drift failure in docs/CI_RELEASE_RUNBOOK.md.
    /^OpenBurnBarSafariExtension\//,
    /^extensions\/safari\//,
    // extensions/safari/scripts/build.mjs copies this icon straight into the
    // Safari dist. The path otherwise belongs to the VS Code extension (web
    // lane), so without this an icon change merges without rebuilding the
    // Safari bundle and ships a stale asset past the byte-for-byte dist gate.
    /^extensions\/openburnbar\/media\/app-icon-128\.png$/,
    /^scripts\/(?:test-openburnbar-app|diff-coverage)(?:[^/]*)$/,
    /^\.github\/workflows\/app-pr-gate\.yml$/,
  ],
  mobile: [
    /^OpenBurnBarMobile\//,
    /^OpenBurnBarMobileTests\//,
    /^scripts\/(?:test-openburnbar-mobile|cross-platform\/(?:setup|run)-ios)/,
    /^\.github\/workflows\/app-pr-gate\.yml$/,
  ],
  android: [
    /^android\//,
    /^scripts\/(?:test-openburnbar-android|cross-platform\/(?:setup|run)-android|build-iroh-android-aar|build_opus_android)/,
    /^\.github\/workflows\/android-pr-gate\.yml$/,
  ],
  rust: [
    /^crates\//,
    /^domain-core\//,
    /^bindings\//,
    /^scripts\/domain-core\//,
    /^tools\/(?:hermes-platform-burnbar|openburnbar-mcp)\//,
    /^\.github\/workflows\/domain-core\.yml$/,
  ],
  daemon: [
    /^OpenBurnBarDaemon\//,
    /^OpenBurnBarDaemonTests\//,
    /^scripts\/test-openburnbar-(?:daemon|swift)/,
    /^\.github\/workflows\/daemon-pr-gate\.yml$/,
  ],
  functions: [
    /^functions\//,
    /^firestore-rules-tests\//,
    /^scripts\/(?:test-functions|verify-functions)/,
    ...NODE_SIGNAL_ENVELOPE_CONTRACTS,
  ],
  web: [/^(website|web|extensions\/openburnbar|plugins\/openburnbar)\//],
  console: [/^(apps\/console|console)\//],
};

const SHARED_SWIFT = [
  /^OpenBurnBarCore\//,
  /^OpenBurnBarShared\//,
  /^CloudSync\//,
];
const DOMAIN_CORE_TRANSITIVE = [
  /domain[-_]?core/i,
  /^AgentLens\/Services\/ProviderQuota\//,
  /^OpenBurnBarCore\/Sources\/OpenBurnBarCore\/(?:ProviderQuota\/|Services\/LogParser\/(?:ModelPricing|DomainCorePricingAdapter)\.swift$)/,
  /^AgentLens\/Services\/(?:ProviderUsageAPI\/.*UsageAPI|UsageAggregatorParsers.*|CursorConnector\/CursorConnectorManager)\.swift$/,
  /^AgentLens\/Views\/Chat\/ChatSessionController\+Retrieval\.swift$/,
  /^windows\/(?:app\/OpenBurnBar\.App\.Presentation\/Quota\/|app\/OpenBurnBar\.App\.CloudSync\/(?:DomainCoreShadowEvidenceUploader|WinAppCloudSyncHost)\.cs$|app\/OpenBurnBar\.App\.CloudSync\/(?:Pensieve\/|Legacy\/PensieveVectorLegacy\.cs$)|tests\/(?:quota|cloudsync)\/|app\/OpenBurnBar\.App\.Configuration\/DomainCoreBuildProfileResolver\.cs$|tests\/configuration\/DomainCoreBuildProfileResolverTests\.cs$|cloudsync\/OpenBurnBar\.CloudSync\.Crypto\/|tests\/cloudsync-app\/PensieveVectorCloakTests\.cs$)/,
  /^android\/app\/src\/(?:main|test)\/java\/com\/openburnbar\/data\/(?:cloud\/CloudVault|hermes\/)/,
  /^apps\/console\/(?:lib\/(?:escrow|recall|legacy\/pensieveVectorLegacy)\.ts$|test\/(?:escrow|domainCoreCloudVault).*\.test\.ts$|vendor\/openburnbar-domain-core-wasm\/)/,
  /^tools\/openburnbar-mcp-remote\/(?:src\/(?:embed|domainCoreCloudVault|legacy\/pensieveVectorLegacy)\.ts$|vendor\/openburnbar-domain-core-wasm\/)/,
  /^functions\/src\/(?:health|index|pricing|rollupCounters|insightsHostedAnswer)\.ts$/,
];

function globToRegExp(glob) {
  let source = "^";
  for (let index = 0; index < glob.length; index += 1) {
    const character = glob[index];
    if (character === "*") {
      if (glob[index + 1] === "*") {
        index += 1;
        if (glob[index + 1] === "/") {
          index += 1;
          source += "(?:.*/)?";
        } else {
          source += ".*";
        }
      } else {
        source += "[^/]*";
      }
    } else if (character === "?") {
      source += "[^/]";
    } else {
      source += character.replace(/[\\^$.*+?()[\]{}|]/gu, "\\$&");
    }
  }
  return new RegExp(`${source}$`, "u");
}

const DOMAIN_CORE_OWNED_PATH_PATTERNS =
  DOMAIN_CORE_OWNED_PATH_GLOBS.map(globToRegExp);

function allLanes(value) {
  return Object.fromEntries(LANES.map((lane) => [lane, value]));
}

function matchesAny(path, patterns) {
  return patterns.some((pattern) => pattern.test(path));
}

export function classifyPaths(
  paths,
  { eventName = "pull_request", labels = [] } = {},
) {
  const cleanPaths = [
    ...new Set(paths.map((path) => path.trim()).filter(Boolean)),
  ].sort();
  const normalizedLabels = labels.map((label) => String(label).toLowerCase());
  const forcedEvent = ["schedule", "workflow_dispatch", "release"].includes(
    eventName,
  );
  const forcedLabel = normalizedLabels.includes("full-ci");

  if (forcedEvent || forcedLabel) {
    return {
      full: true,
      reason: forcedEvent ? `event:${eventName}` : "label:full-ci",
      paths: cleanPaths,
      ...allLanes(true),
    };
  }
  if (cleanPaths.length === 0) {
    return {
      full: true,
      reason: "unresolved-or-empty-diff",
      paths: cleanPaths,
      ...allLanes(true),
    };
  }
  if (
    cleanPaths.some(
      (path) =>
        !matchesAny(path, FULL_PATTERN_EXEMPTIONS) &&
        matchesAny(path, FULL_PATTERNS),
    )
  ) {
    return {
      full: true,
      reason: "shared-or-sensitive-path",
      paths: cleanPaths,
      ...allLanes(true),
    };
  }

  const lanes = allLanes(false);
  const ambiguous = [];
  for (const path of cleanPaths) {
    let owned = false;
    if (matchesAny(path, SHARED_SWIFT)) {
      lanes.macos = lanes.mobile = lanes.daemon = true;
      owned = true;
    }
    if (
      matchesAny(path, DOMAIN_CORE_TRANSITIVE) ||
      matchesAny(path, DOMAIN_CORE_OWNED_PATH_PATTERNS)
    ) {
      lanes.rust = true;
      owned = true;
    }
    for (const lane of LANES) {
      if (matchesAny(path, LANE_PATTERNS[lane])) {
        lanes[lane] = true;
        owned = true;
      }
    }
    if (!owned && !matchesAny(path, SAFE_NO_PRODUCT_PATTERNS))
      ambiguous.push(path);
  }
  if (ambiguous.length > 0) {
    return {
      full: true,
      reason: `ambiguous:${ambiguous.join(",")}`,
      paths: cleanPaths,
      ...allLanes(true),
    };
  }
  return { full: false, reason: "owned-paths", paths: cleanPaths, ...lanes };
}

export function gitDiff(base, head, cwd = process.cwd()) {
  return execFileSync(
    "git",
    ["diff", "--name-only", "--no-renames", base, head],
    { cwd, encoding: "utf8" },
  )
    .split("\n")
    .filter(Boolean);
}

export function classifyEvent(event, eventName, diff = gitDiff) {
  const labels = event.pull_request?.labels?.map((label) => label.name) ?? [];
  if (["schedule", "workflow_dispatch", "release"].includes(eventName)) {
    return classifyPaths(["forced/event"], { eventName, labels });
  }
  const base =
    eventName === "merge_group"
      ? event.merge_group?.base_sha
      : eventName === "push"
        ? event.before
        : event.pull_request?.base?.sha;
  const head =
    eventName === "merge_group"
      ? event.merge_group?.head_sha
      : eventName === "push"
        ? event.after
        : event.pull_request?.head?.sha;
  if (!base || !head || /^0{40}$/u.test(base) || /^0{40}$/u.test(head)) {
    return classifyPaths([], { eventName, labels });
  }
  try {
    return classifyPaths(diff(base, head), { eventName, labels });
  } catch {
    // A push run is the authoritative deploy proof for its exact after
    // commit. When the exact before..after range is unavailable (for
    // example a multi-commit push beyond the shallow checkout), any
    // partial fallback like HEAD^..HEAD would under-classify earlier
    // commits in the push, so pushes fail closed to a full run.
    if (eventName === "push") return classifyPaths([], { eventName, labels });
    try {
      return classifyPaths(diff("HEAD^1", "HEAD^2"), { eventName, labels });
    } catch {
      return classifyPaths([], { eventName, labels });
    }
  }
}

function main() {
  const args = Object.fromEntries(
    process.argv.slice(2).reduce((pairs, value, index, all) => {
      if (value.startsWith("--")) pairs.push([value.slice(2), all[index + 1]]);
      return pairs;
    }, []),
  );
  const eventPath = args["event-path"] ?? process.env.GITHUB_EVENT_PATH;
  const eventName = args["event-name"] ?? process.env.GITHUB_EVENT_NAME;
  if (!eventPath || !eventName)
    throw new Error("event path and event name are required");
  const result = classifyEvent(
    JSON.parse(readFileSync(eventPath, "utf8")),
    eventName,
  );
  const lines =
    ["full", "reason", ...LANES]
      .map((key) => `${key}=${result[key]}`)
      .join("\n") + "\n";
  const output = args.output ?? process.env.GITHUB_OUTPUT;
  if (output) appendFileSync(output, lines);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main();
