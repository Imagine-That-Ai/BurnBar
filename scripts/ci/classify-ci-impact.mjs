#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, appendFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

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

const FULL_PATTERNS = [
  /(^|\/)(Package\.swift|Package\.resolved|Cargo\.toml|Cargo\.lock|build\.gradle(?:\.kts)?|settings\.gradle(?:\.kts)?|gradle\.properties|package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|[^/]+\.csproj|[^/]+\.slnx?|Directory\.Build\.(?:props|targets)|global\.json|packages\.lock\.json)$/,
  /^(OpenBurnBar\.xcodeproj|OpenBurnBar\.xcworkspace|tools\/schema-sync|Vendor\/|scripts\/lib\/|scripts\/release\/|scripts\/security\/)/,
  /^(governance\/|security\/|\.github\/CODEOWNERS|\.github\/dependabot\.yml)/,
  /^\.github\/workflows\/(?:burnbar-ci-gate|ci-impact|deploy-|release|security|codeql|dependency|secret|osv)/,
  /^scripts\/ci\/(?:classify-ci-impact|await-burnbar-ci-gate)/,
  /^(firebase\.json|firestore\.|storage\.|apphosting\.|Dockerfile|Makefile|Brewfile)/,
];

const SAFE_NO_PRODUCT_PATTERNS = [
  /^(docs\/|droid-wiki\/|plans\/|\.github\/(?:ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE)|CHANGELOG\.md$|README\.md$|AGENTS\.md$|CLAUDE\.md$)/,
  /^\.github\/workflows\//,
  /^(tests\/|scripts\/ci\/).*\.(?:py|mjs|js|sh|json|ya?ml)$/,
  /^windows\/tests\//,
];

const LANE_PATTERNS = {
  macos: [
    /^AgentLens\//,
    /^AgentLensTests\//,
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
  ],
  web: [/^(website|web|extensions\/openburnbar)\//],
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
  if (cleanPaths.some((path) => matchesAny(path, FULL_PATTERNS))) {
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
    if (matchesAny(path, DOMAIN_CORE_TRANSITIVE)) {
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

function gitDiff(base, head) {
  return execFileSync(
    "git",
    ["diff", "--name-only", "--diff-filter=ACMR", base, head],
    { encoding: "utf8" },
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
      : event.pull_request?.base?.sha;
  const head =
    eventName === "merge_group"
      ? event.merge_group?.head_sha
      : event.pull_request?.head?.sha;
  if (!base || !head) return classifyPaths([], { eventName, labels });
  try {
    return classifyPaths(diff(base, head), { eventName, labels });
  } catch {
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
