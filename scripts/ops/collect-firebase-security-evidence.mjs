#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { evaluateFirebaseAppCheckEnforcement } from "../lib/evaluate-firebase-app-check-enforcement.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_APP_CHECK_SERVICES = [
  "firestore.googleapis.com",
  "firebasestorage.googleapis.com",
];
const DEFAULT_FUNCTION_REGIONS = ["us-central1"];
const DEFAULT_KMS_LOCATIONS = [
  "global",
  "us",
  "us-central1",
  "us-east1",
  "us-east4",
  "northamerica-northeast1",
];

function usage() {
  console.log(`Usage: node scripts/ops/collect-firebase-security-evidence.mjs [options]

Read-only Firebase/GCP evidence collector for auditor and launch-gate use.
It does not read Secret Manager secret payloads or print OAuth access tokens.

Options:
  --project <id>             Firebase/GCP project id. Defaults to FIREBASE_PROJECT, OPENBURNBAR_FIREBASE_PROJECT, GCLOUD_PROJECT, or burnbar.
  --output <path>            Output JSON path. Defaults to security/evidence/firebase-security-evidence-<timestamp>.json.
  --strict                   Exit nonzero when critical live controls cannot be verified.
  --region <region>          Cloud Functions region to collect. Repeatable.
  --kms-location <location>  KMS location to inspect. Repeatable.
  --app-check-service <svc>  Firebase App Check service to inspect. Repeatable.
  --help                     Show this help.
`);
}

function parseArgs(argv) {
  const options = {
    project:
      process.env.FIREBASE_PROJECT ||
      process.env.OPENBURNBAR_FIREBASE_PROJECT ||
      process.env.GCLOUD_PROJECT ||
      "burnbar",
    output: "",
    strict: false,
    regions: [],
    kmsLocations: [],
    appCheckServices: [],
  };

  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--strict") {
      options.strict = true;
      continue;
    }
    if (arg === "--project") {
      options.project = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--output") {
      options.output = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--region") {
      options.regions.push(requireValue(argv, ++index, arg));
      continue;
    }
    if (arg === "--kms-location") {
      options.kmsLocations.push(requireValue(argv, ++index, arg));
      continue;
    }
    if (arg === "--app-check-service") {
      options.appCheckServices.push(requireValue(argv, ++index, arg));
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  options.regions = uniqueNonEmpty([
    ...options.regions,
    ...splitCsv(process.env.FUNCTIONS_REGION),
    ...splitCsv(process.env.FUNCTIONS_REGIONS),
  ]);
  if (options.regions.length === 0) options.regions = DEFAULT_FUNCTION_REGIONS;

  options.kmsLocations = uniqueNonEmpty([
    ...options.kmsLocations,
    ...splitCsv(process.env.KMS_LOCATIONS),
  ]);
  if (options.kmsLocations.length === 0) {
    options.kmsLocations = DEFAULT_KMS_LOCATIONS;
  }

  options.appCheckServices = uniqueNonEmpty([
    ...options.appCheckServices,
    ...splitCsv(process.env.FIREBASE_APP_CHECK_SERVICES),
  ]);
  if (options.appCheckServices.length === 0) {
    options.appCheckServices = DEFAULT_APP_CHECK_SERVICES;
  }

  if (!options.output) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    options.output = resolve(
      repoRoot,
      "security",
      "evidence",
      `firebase-security-evidence-${stamp}.json`,
    );
  } else {
    options.output = resolve(repoRoot, options.output);
  }

  return options;
}

function requireValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function splitCsv(value) {
  if (!value) return [];
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function uniqueNonEmpty(values) {
  return [...new Set(values.map((value) => value.trim()).filter(Boolean))];
}

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function redactString(value) {
  return value
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/g, "Bearer [REDACTED]")
    .replace(/ya29\.[A-Za-z0-9._~+/=-]+/g, "[REDACTED_GOOGLE_TOKEN]")
    .replace(
      /(AIza[0-9A-Za-z_-]{20,})/g,
      "[REDACTED_FIREBASE_WEB_API_KEY]",
    );
}

function isSensitiveKey(key) {
  return /(^|[_-])(access|refresh|id)?token($|[_-])|authorization|cookie|password|passphrase|private[_-]?key|credentials|client[_-]?secret|secret[_-]?data|payload/i.test(
    key,
  );
}

function redact(value) {
  if (value === null || value === undefined) return value;
  if (typeof value === "string") return redactString(value);
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (typeof value !== "object") return value;

  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key,
      isSensitiveKey(key) ? "[REDACTED]" : redact(item),
    ]),
  );
}

function run(command, args, options = {}) {
  try {
    const stdout = execFileSync(command, args, {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: options.timeout ?? 120_000,
      env: { ...process.env, ...(options.env || {}) },
    });
    const trimmed = stdout.trim();
    return {
      ok: true,
      command: [command, ...args],
      stdout: options.json ? JSON.parse(trimmed || "null") : redactString(trimmed),
    };
  } catch (error) {
    const stdout =
      typeof error.stdout === "string"
        ? error.stdout
        : error.stdout?.toString?.() || "";
    const stderr =
      typeof error.stderr === "string"
        ? error.stderr
        : error.stderr?.toString?.() || "";
    return {
      ok: false,
      command: [command, ...args],
      error: redactString(stderr || stdout || error.message || String(error)),
      exitCode: typeof error.status === "number" ? error.status : null,
    };
  }
}

function commandJson(command, args, options) {
  return redact(run(command, [...args, "--format=json"], { ...options, json: true }));
}

function gcloudJson(args, options) {
  return commandJson("gcloud", args, options);
}

function firebaseJson(args, options) {
  return redact(
    run(
      "npx",
      ["--prefix", "functions", "firebase", "--project", options.project, "--json", ...args],
      { ...options, json: true },
    ),
  );
}

function accessToken() {
  if (process.env.GOOGLE_OAUTH_ACCESS_TOKEN) {
    return process.env.GOOGLE_OAUTH_ACCESS_TOKEN;
  }
  const args = ["auth", "print-access-token"];
  if (process.env.GOOGLE_IMPERSONATE_SERVICE_ACCOUNT) {
    args.push(
      "--impersonate-service-account",
      process.env.GOOGLE_IMPERSONATE_SERVICE_ACCOUNT,
    );
  }
  try {
    return execFileSync("gcloud", args, {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 60_000,
    }).trim();
  } catch (error) {
    const stdout =
      typeof error.stdout === "string"
        ? error.stdout
        : error.stdout?.toString?.() || "";
    const stderr =
      typeof error.stderr === "string"
        ? error.stderr
        : error.stderr?.toString?.() || "";
    throw new Error(redactString(stderr || stdout || error.message || String(error)));
  }
}

async function apiJson(url, token, project) {
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      "X-Goog-User-Project": project,
    },
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`${response.status} ${redactString(body)}`);
  }
  return JSON.parse(body || "{}");
}

async function firebaseRulesGet(path, token, project) {
  return apiJson(`https://firebaserules.googleapis.com/v1/${path}`, token, project);
}

async function deployedRulesForRelease(releasePath, fileName, token, project) {
  const release = await firebaseRulesGet(releasePath, token, project);
  if (typeof release.rulesetName !== "string") {
    throw new Error(`${releasePath} did not include rulesetName`);
  }
  const ruleset = await firebaseRulesGet(release.rulesetName, token, project);
  const files = Array.isArray(ruleset.source?.files)
    ? ruleset.source.files
    : [];
  const rulesFile = files.find(
    (file) => file?.name === fileName || file?.name?.endsWith(`/${fileName}`),
  );
  if (typeof rulesFile?.content !== "string") {
    throw new Error(
      `ruleset ${release.rulesetName} did not include ${fileName} content`,
    );
  }
  return {
    releaseName: release.name || releasePath,
    rulesetName: release.rulesetName,
    updateTime: release.updateTime || null,
    content: rulesFile.content,
  };
}

async function storageReleasePaths(token, project) {
  const listing = await firebaseRulesGet(`projects/${project}/releases`, token, project);
  const releases = Array.isArray(listing.releases) ? listing.releases : [];
  return releases
    .map((release) => release?.name)
    .filter(
      (name) =>
        typeof name === "string" && name.includes("/releases/firebase.storage/"),
    );
}

function normalizedIndexSpec(raw) {
  const indexes = Array.isArray(raw.indexes) ? raw.indexes : [];
  const fieldOverrides = Array.isArray(raw.fieldOverrides)
    ? raw.fieldOverrides
    : [];
  const compact = (entry) =>
    Object.fromEntries(
      Object.entries(entry).filter(
        ([, value]) => value !== undefined && value !== null,
      ),
    );
  return {
    indexes: indexes
      .map((index) => ({
        collectionGroup: index.collectionGroup,
        queryScope: index.queryScope,
        fields: Array.isArray(index.fields)
          ? index.fields
              .filter((field) => field.fieldPath !== "__name__")
              .map((field) =>
                compact({
                  fieldPath: field.fieldPath,
                  order: field.order,
                  arrayConfig: field.arrayConfig,
                  vectorConfig: field.vectorConfig,
                }),
              )
          : [],
      }))
      .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
    fieldOverrides: fieldOverrides
      .map((override) =>
        compact({
          collectionGroup: override.collectionGroup,
          fieldPath: override.fieldPath,
          indexes: Array.isArray(override.indexes)
            ? override.indexes.map((index) =>
                compact({
                  order: index.order,
                  arrayConfig: index.arrayConfig,
                  queryScope: index.queryScope,
                }),
              )
            : [],
          ttl: override.ttl || undefined,
        }),
      )
      .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))),
  };
}

async function collectRules(project, token) {
  const localFirestoreRules = readFileSync(
    resolve(repoRoot, "firestore.rules"),
    "utf8",
  );
  const remoteFirestoreRules = await deployedRulesForRelease(
    `projects/${project}/releases/cloud.firestore`,
    "firestore.rules",
    token,
    project,
  );
  const firestore = {
    releaseName: remoteFirestoreRules.releaseName,
    rulesetName: remoteFirestoreRules.rulesetName,
    updateTime: remoteFirestoreRules.updateTime,
    localSha256: sha256(localFirestoreRules.trimEnd()),
    deployedSha256: sha256(remoteFirestoreRules.content.trimEnd()),
  };
  firestore.drift = firestore.localSha256 !== firestore.deployedSha256;

  const localIndexes = normalizedIndexSpec(
    JSON.parse(readFileSync(resolve(repoRoot, "firestore.indexes.json"), "utf8")),
  );
  const deployedIndexesResult = firebaseJson(["firestore:indexes"], {
    project,
    timeout: 120_000,
  });
  let firestoreIndexes = {
    ok: deployedIndexesResult.ok,
    localSha256: sha256(JSON.stringify(localIndexes)),
    deployedSha256: null,
    drift: null,
    error: deployedIndexesResult.ok ? undefined : deployedIndexesResult.error,
  };
  if (deployedIndexesResult.ok) {
    const deployedIndexes = normalizedIndexSpec(
      deployedIndexesResult.stdout?.result ?? deployedIndexesResult.stdout,
    );
    const deployedSha256 = sha256(JSON.stringify(deployedIndexes));
    firestoreIndexes = {
      ok: true,
      localSha256: firestoreIndexes.localSha256,
      deployedSha256,
      drift: firestoreIndexes.localSha256 !== deployedSha256,
      indexCount: deployedIndexes.indexes.length,
      fieldOverrideCount: deployedIndexes.fieldOverrides.length,
    };
  }

  const localStorageRules = readFileSync(resolve(repoRoot, "storage.rules"), "utf8");
  const storageLocalSha256 = sha256(localStorageRules.trimEnd());
  const storageReleases = await storageReleasePaths(token, project);
  const storage = [];
  for (const releasePath of storageReleases) {
    const remoteStorageRules = await deployedRulesForRelease(
      releasePath,
      "storage.rules",
      token,
      project,
    );
    const deployedSha256 = sha256(remoteStorageRules.content.trimEnd());
    storage.push({
      releaseName: remoteStorageRules.releaseName,
      rulesetName: remoteStorageRules.rulesetName,
      updateTime: remoteStorageRules.updateTime,
      localSha256: storageLocalSha256,
      deployedSha256,
      drift: storageLocalSha256 !== deployedSha256,
    });
  }

  return {
    ok:
      !firestore.drift &&
      firestoreIndexes.ok &&
      firestoreIndexes.drift === false &&
      storage.length > 0 &&
      storage.every((entry) => entry.drift === false),
    firestore,
    firestoreIndexes,
    storage,
  };
}

async function collectAppCheck(project, projectNumber, token, services) {
  const serviceResults = [];
  for (const service of services) {
    const serviceName = `projects/${projectNumber}/services/${service}`;
    try {
      const config = await apiJson(
        `https://firebaseappcheck.googleapis.com/v1beta/${serviceName}`,
        token,
        project,
      );
      const evaluation = evaluateFirebaseAppCheckEnforcement({
        serviceName,
        enforcementMode: config.enforcementMode || null,
        updateTime: config.updateTime || null,
        probe: "live",
      });
      serviceResults.push({ service, ...evaluation });
    } catch (error) {
      serviceResults.push({
        ok: false,
        service,
        serviceName,
        enforcementMode: null,
        probe: "live",
        error: error.message,
      });
    }
  }

  return {
    ok: serviceResults.every((entry) => entry.ok),
    services: serviceResults,
  };
}

function collectProject(project) {
  const projectDescribe = gcloudJson(["projects", "describe", project], {
    timeout: 60_000,
  });
  return {
    ok: projectDescribe.ok,
    projectId: project,
    projectNumber: projectDescribe.stdout?.projectNumber || null,
    lifecycleState: projectDescribe.stdout?.lifecycleState || null,
    labels: projectDescribe.stdout?.labels || {},
    error: projectDescribe.ok ? undefined : projectDescribe.error,
  };
}

function collectAuthContext(project) {
  return {
    gcloudProject: run("gcloud", ["config", "get-value", "project"], {
      timeout: 30_000,
    }),
    activeAccount: run("gcloud", ["config", "get-value", "account"], {
      timeout: 30_000,
    }),
    firebaseProjects: firebaseJson(["projects:list"], {
      project,
      timeout: 90_000,
    }),
  };
}

function summarizePolicy(policy) {
  const bindings = Array.isArray(policy?.bindings) ? policy.bindings : [];
  return {
    etag: policy?.etag || null,
    version: policy?.version || null,
    bindingCount: bindings.length,
    bindings: bindings.map((binding) => ({
      role: binding.role || null,
      members: Array.isArray(binding.members) ? binding.members.slice().sort() : [],
      condition: binding.condition || null,
    })),
  };
}

function collectIam(project) {
  const policy = gcloudJson(["projects", "get-iam-policy", project], {
    timeout: 90_000,
  });
  return {
    ok: policy.ok,
    project: policy.ok ? summarizePolicy(policy.stdout) : null,
    error: policy.ok ? undefined : policy.error,
  };
}

function collectFunctions(project, regions) {
  return {
    ok: true,
    regions: Object.fromEntries(
      regions.map((region) => {
        const result = gcloudJson(
          ["functions", "list", "--v2", "--regions", region],
          { timeout: 120_000 },
        );
        const functions = result.ok && Array.isArray(result.stdout)
          ? result.stdout.map((fn) => ({
              name: fn.name || null,
              state: fn.state || null,
              updateTime: fn.updateTime || null,
              url: fn.serviceConfig?.uri || fn.url || null,
              ingressSettings: fn.serviceConfig?.ingressSettings || null,
              serviceAccountEmail: fn.serviceConfig?.serviceAccountEmail || null,
              availableMemory: fn.serviceConfig?.availableMemory || null,
              timeoutSeconds: fn.serviceConfig?.timeoutSeconds || null,
              minInstanceCount: fn.serviceConfig?.minInstanceCount || null,
              maxInstanceCount: fn.serviceConfig?.maxInstanceCount || null,
              allTrafficOnLatestRevision:
                fn.serviceConfig?.allTrafficOnLatestRevision ?? null,
              secretEnvironmentVariableNames: Array.isArray(
                fn.serviceConfig?.secretEnvironmentVariables,
              )
                ? fn.serviceConfig.secretEnvironmentVariables
                    .map((item) => item.key || item.secret || item.projectId)
                    .filter(Boolean)
                    .sort()
                : [],
              labels: fn.labels || {},
            }))
          : [];
        return [
          region,
          {
            ok: result.ok,
            count: functions.length,
            functions,
            error: result.ok ? undefined : result.error,
          },
        ];
      }),
    ),
  };
}

function bucketNameFromUrl(url) {
  const value = String(url || "");
  if (value.includes("/buckets/")) return value.split("/buckets/").pop();
  return value.replace(/^gs:\/\//, "").replace(/\/.*$/, "");
}

function collectStorageBuckets(project) {
  const list = gcloudJson(["storage", "buckets", "list", "--project", project], {
    timeout: 120_000,
  });
  if (!list.ok) return { ok: false, error: list.error, buckets: [] };

  const buckets = Array.isArray(list.stdout) ? list.stdout : [];
  const results = buckets.map((bucket) => {
    const url = bucket.storageUrl || bucket.url || `gs://${bucketNameFromUrl(bucket.name || "")}`;
    const describe = gcloudJson(["storage", "buckets", "describe", url], {
      timeout: 90_000,
    });
    const iam = gcloudJson(["storage", "buckets", "get-iam-policy", url], {
      timeout: 90_000,
    });
    const detail = describe.ok ? describe.stdout : bucket;
    return {
      ok: describe.ok && iam.ok,
      name: detail.name || bucket.name || null,
      url,
      location: detail.location || null,
      storageClass: detail.storageClass || null,
      uniformBucketLevelAccess:
        detail.iamConfiguration?.uniformBucketLevelAccess?.enabled ?? null,
      publicAccessPrevention: detail.iamConfiguration?.publicAccessPrevention || null,
      retentionPolicy: detail.retentionPolicy || null,
      encryption: detail.encryption || null,
      lifecycle: detail.lifecycle || null,
      iamPolicy: iam.ok ? summarizePolicy(iam.stdout) : null,
      error: [describe.error, iam.error].filter(Boolean).join("; ") || undefined,
    };
  });

  return {
    ok: results.every((bucket) => bucket.ok),
    bucketCount: results.length,
    buckets: redact(results),
  };
}

function collectSecrets(project) {
  const list = gcloudJson(["secrets", "list", "--project", project], {
    timeout: 120_000,
  });
  if (!list.ok) return { ok: false, error: list.error, secrets: [] };

  const secrets = Array.isArray(list.stdout) ? list.stdout : [];
  const results = secrets.map((secret) => {
    const name = secret.name || "";
    const secretId = name.split("/").pop();
    const iam = secretId
      ? gcloudJson(["secrets", "get-iam-policy", secretId, "--project", project], {
          timeout: 90_000,
        })
      : { ok: false, error: "secret id missing" };
    return {
      ok: iam.ok,
      name,
      replication: secret.replication || null,
      labels: secret.labels || {},
      createTime: secret.createTime || null,
      expireTime: secret.expireTime || null,
      topics: secret.topics || [],
      iamPolicy: iam.ok ? summarizePolicy(iam.stdout) : null,
      error: iam.ok ? undefined : iam.error,
    };
  });

  return {
    ok: results.every((secret) => secret.ok),
    secretCount: results.length,
    secrets: redact(results),
  };
}

function keyRingId(keyRing) {
  return String(keyRing.name || "").split("/keyRings/").pop();
}

function collectKms(project, locations) {
  const locationResults = {};
  for (const location of locations) {
    const keyrings = gcloudJson(
      ["kms", "keyrings", "list", "--project", project, "--location", location],
      { timeout: 90_000 },
    );
    if (!keyrings.ok) {
      locationResults[location] = {
        ok: false,
        keyRingCount: 0,
        keyCount: 0,
        error: keyrings.error,
        keyRings: [],
      };
      continue;
    }
    const rings = Array.isArray(keyrings.stdout) ? keyrings.stdout : [];
    const ringResults = rings.map((ring) => {
      const ringId = keyRingId(ring);
      const keys = gcloudJson(
        [
          "kms",
          "keys",
          "list",
          "--project",
          project,
          "--location",
          location,
          "--keyring",
          ringId,
        ],
        { timeout: 90_000 },
      );
      const keyEntries = Array.isArray(keys.stdout) ? keys.stdout : [];
      const keyResults = keyEntries.map((key) => {
        const keyId = String(key.name || "").split("/cryptoKeys/").pop();
        const iam = gcloudJson(
          [
            "kms",
            "keys",
            "get-iam-policy",
            keyId,
            "--project",
            project,
            "--location",
            location,
            "--keyring",
            ringId,
          ],
          { timeout: 90_000 },
        );
        return {
          ok: iam.ok,
          name: key.name || null,
          purpose: key.purpose || null,
          createTime: key.createTime || null,
          rotationPeriod: key.rotationPeriod || null,
          nextRotationTime: key.nextRotationTime || null,
          protectionLevel: key.primary?.protectionLevel || null,
          primaryState: key.primary?.state || null,
          primaryAlgorithm: key.primary?.algorithm || null,
          labels: key.labels || {},
          iamPolicy: iam.ok ? summarizePolicy(iam.stdout) : null,
          error: iam.ok ? undefined : iam.error,
        };
      });
      return {
        ok: keys.ok && keyResults.every((key) => key.ok),
        name: ring.name || null,
        createTime: ring.createTime || null,
        keyCount: keyResults.length,
        keys: keyResults,
        error: keys.ok ? undefined : keys.error,
      };
    });
    locationResults[location] = {
      ok: ringResults.every((ring) => ring.ok),
      keyRingCount: ringResults.length,
      keyCount: ringResults.reduce((sum, ring) => sum + ring.keyCount, 0),
      keyRings: redact(ringResults),
    };
  }

  return {
    ok: Object.values(locationResults).every((location) => location.ok),
    locations: locationResults,
  };
}

function deriveSummary(evidence) {
  const appCheckFirestore = evidence.appCheck?.services?.find(
    (entry) => entry.service === "firestore.googleapis.com",
  );
  const appCheckStorage = evidence.appCheck?.services?.find(
    (entry) => entry.service === "firebasestorage.googleapis.com",
  );
  const functionRegions = Object.values(evidence.functions?.regions || {});
  return {
    projectCollected: evidence.project?.ok === true,
    firestoreAppCheckEnforced: appCheckFirestore?.ok === true,
    storageAppCheckEnforced: appCheckStorage?.ok === true,
    firestoreRulesMatchRepo:
      evidence.rules?.firestore?.drift === false &&
      evidence.rules?.firestoreIndexes?.drift === false,
    storageRulesMatchRepo:
      Array.isArray(evidence.rules?.storage) &&
      evidence.rules.storage.length > 0 &&
      evidence.rules.storage.every((entry) => entry.drift === false),
    projectIamCollected: evidence.iam?.ok === true,
    functionInventoryCollected:
      functionRegions.length > 0 && functionRegions.every((entry) => entry.ok),
    storageBucketInventoryCollected: evidence.storageBuckets?.ok === true,
    secretIamCollected: evidence.secrets?.ok === true,
    kmsInventoryCollected: evidence.kms?.ok === true,
  };
}

async function collect(options) {
  const evidence = {
    schemaVersion: 1,
    collectedAt: new Date().toISOString(),
    collector: "scripts/ops/collect-firebase-security-evidence.mjs",
    mode: {
      strict: options.strict,
      regions: options.regions,
      kmsLocations: options.kmsLocations,
      appCheckServices: options.appCheckServices,
    },
    project: collectProject(options.project),
    authContext: collectAuthContext(options.project),
  };
  if (!evidence.project.ok || !evidence.project.projectNumber) {
    evidence.summary = deriveSummary(evidence);
    evidence.ok = false;
    return evidence;
  }

  let token = "";
  try {
    token = accessToken();
  } catch (error) {
    evidence.tokenProbe = { ok: false, error: error.message };
    evidence.summary = deriveSummary(evidence);
    evidence.ok = false;
    return evidence;
  }
  evidence.tokenProbe = { ok: true, source: process.env.GOOGLE_OAUTH_ACCESS_TOKEN ? "env" : "gcloud" };

  const collectors = [
    ["rules", () => collectRules(options.project, token)],
    [
      "appCheck",
      () =>
        collectAppCheck(
          options.project,
          evidence.project.projectNumber,
          token,
          options.appCheckServices,
        ),
    ],
    ["iam", () => collectIam(options.project)],
    ["functions", () => collectFunctions(options.project, options.regions)],
    ["storageBuckets", () => collectStorageBuckets(options.project)],
    ["secrets", () => collectSecrets(options.project)],
    ["kms", () => collectKms(options.project, options.kmsLocations)],
  ];

  for (const [name, collector] of collectors) {
    try {
      evidence[name] = await collector();
    } catch (error) {
      evidence[name] = { ok: false, error: error.message };
    }
  }

  evidence.summary = deriveSummary(evidence);
  evidence.ok = Object.values(evidence.summary).every(Boolean);
  return redact(evidence);
}

const options = parseArgs(process.argv);
const evidence = await collect(options);
mkdirSync(dirname(options.output), { recursive: true });
writeFileSync(options.output, `${JSON.stringify(evidence, null, 2)}\n`);

console.log(
  JSON.stringify(
    {
      ok: evidence.ok,
      output: options.output,
      summary: evidence.summary,
    },
    null,
    2,
  ),
);

if (options.strict && !evidence.ok) {
  process.exitCode = 1;
}
