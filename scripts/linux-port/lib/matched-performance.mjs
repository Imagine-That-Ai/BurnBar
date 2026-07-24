import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const PERCENTILE_KEYS = ['minimum', 'p50', 'p95', 'p99', 'maximum'];
export const MATCHED_PERFORMANCE_SOURCE_FILES = Object.freeze([
  "budgets/linux-desktop.perf.json",
  "scripts/linux-port/run-matched-performance.mjs",
  "scripts/linux-port/lib/matched-performance.mjs",
  "tools/matched-performance/Package.swift",
  "tools/matched-performance/Sources/OpenBurnBarPerfProbe/main.swift",
  "tools/matched-performance/Sources/OpenBurnBarStreamPerfProbe/main.swift",
]);

export function matchedPerformanceSourceDigest(root) {
  const hash = crypto.createHash("sha256");
  for (const relative of MATCHED_PERFORMANCE_SOURCE_FILES) {
    hash.update(relative);
    hash.update("\0");
    hash.update(fs.readFileSync(path.join(root, relative)));
    hash.update("\0");
  }
  return hash.digest("hex");
}

function reportPayloadSha256(report) {
  const payload = structuredClone(report);
  delete payload.provenance;
  return crypto.createHash("sha256").update(JSON.stringify(payload)).digest("hex");
}

export function attachMatchedPerformanceProvenance(report, identity) {
  const value = structuredClone(report);
  value.provenance = {
    schemaVersion: 1,
    producer: "openburnbar-matched-performance-v2",
    platform: identity.platform,
    profile: identity.profile,
    gitCommit: identity.gitCommit,
    packageVersion: identity.packageVersion,
    sourceDigest: identity.sourceDigest,
    candidate: {
      runId: identity.candidateRunId ?? null,
      artifactDigest: identity.candidateArtifactDigest ?? null,
    },
    startedAt: identity.startedAt,
    endedAt: identity.endedAt,
    payloadSha256: "",
  };
  value.provenance.payloadSha256 = reportPayloadSha256(value);
  return value;
}

function validateProvenance(report, platform, profile, expected, errors) {
  const value = report?.provenance;
  const startedAt = Date.parse(value?.startedAt);
  const endedAt = Date.parse(value?.endedAt);
  const generatedAt = Date.parse(report?.generatedAt);
  if (value?.schemaVersion !== 1 || value?.producer !== "openburnbar-matched-performance-v2"
      || value?.platform !== platform || value?.profile !== profile
      || !/^[a-f0-9]{40,64}$/u.test(value?.gitCommit ?? "")
      || !/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u.test(value?.packageVersion ?? "")
      || !/^[a-f0-9]{64}$/u.test(value?.sourceDigest ?? "")
      || !/^[a-f0-9]{64}$/u.test(value?.payloadSha256 ?? "")
      || !Number.isFinite(startedAt) || !Number.isFinite(endedAt) || !Number.isFinite(generatedAt)
      || generatedAt < startedAt || generatedAt > endedAt || endedAt < startedAt
      || value.payloadSha256 !== reportPayloadSha256(report)) {
    errors.push(`${platform} report provenance is missing, invalid, or not payload-bound`);
    return;
  }
  const runId = value.candidate?.runId;
  const digest = value.candidate?.artifactDigest;
  if (!((runId === null && digest === null)
      || (/^[1-9][0-9]*$/u.test(String(runId)) && /^sha256:[a-f0-9]{64}$/u.test(digest ?? "")))) {
    errors.push(`${platform} report candidate provenance is invalid`);
  }
  if (expected) {
    for (const [key, wanted] of Object.entries(expected)) {
      const actual = key === "candidateRunId" ? runId : key === "candidateArtifactDigest" ? digest : value[key];
      if (String(actual) !== String(wanted)) errors.push(`${platform} report provenance ${key} does not match the selected candidate`);
    }
  }
}

export function dockerHostIdentityArguments(uid, gid) {
  if (!Number.isSafeInteger(uid) || uid < 0 || !Number.isSafeInteger(gid) || gid < 0) {
    return [];
  }
  return ['--user', `${uid}:${gid}`, '-e', 'HOME=/tmp/openburnbar-home'];
}

function finiteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

function normalizedArchitecture(value) {
  if (value === 'arm64' || value === 'aarch64') return 'arm64';
  if (value === 'x86_64' || value === 'amd64') return 'x86_64';
  return value;
}

function validatePercentiles(result, platform, errors) {
  const values = PERCENTILE_KEYS.map((key) => result?.percentiles?.[key]);
  if (values.some((value) => !finiteNumber(value) || value < 0)) {
    errors.push(`${platform}:${result?.id ?? 'unknown'} has invalid percentile values`);
    return;
  }
  for (let index = 1; index < values.length; index += 1) {
    if (values[index] < values[index - 1]) {
      errors.push(`${platform}:${result.id} percentile ordering is invalid`);
      return;
    }
  }
}

function validateReport(report, platform, expected, matchedBudget, errors, profile, expectedProvenance) {
  if (!report || typeof report !== 'object') {
    errors.push(`${platform} report is missing or invalid`);
    return new Map();
  }
  if (report.schemaVersion !== 1) errors.push(`${platform} schemaVersion must be 1`);
  if (report.protocolVersion !== matchedBudget.protocolVersion) {
    errors.push(`${platform} protocolVersion is ${report.protocolVersion ?? 'missing'}`);
  }
  if (report.host?.platform !== platform) {
    errors.push(`${platform} report identifies platform ${report.host?.platform ?? 'missing'}`);
  }
  for (const [key, value] of Object.entries(expected)) {
    if (report.configuration?.[key] !== value) {
      errors.push(`${platform} configuration ${key} must be ${value}, got ${report.configuration?.[key] ?? 'missing'}`);
    }
  }
  if (report.pass !== true) errors.push(`${platform} probe did not pass its internal invariants`);
  validateProvenance(report, platform, profile, expectedProvenance, errors);

  const rows = Array.isArray(report.workloads) ? report.workloads : [];
  const ids = rows.map((row) => row?.id);
  if (new Set(ids).size !== ids.length) errors.push(`${platform} report contains duplicate workload ids`);
  const byID = new Map(rows.map((row) => [row?.id, row]));
  for (const id of matchedBudget.expectedWorkloads) {
    const row = byID.get(id);
    if (!row) {
      errors.push(`${platform} report is missing workload ${id}`);
      continue;
    }
    if (row.unit !== 'milliseconds') errors.push(`${platform}:${id} unit must be milliseconds`);
    if (row.sampleCount !== expected.samples) {
      errors.push(`${platform}:${id} sampleCount must be ${expected.samples}`);
    }
    if (!Number.isSafeInteger(row.checksum) || row.checksum === 0) {
      errors.push(`${platform}:${id} checksum is invalid`);
    }
    validatePercentiles(row, platform, errors);
  }
  for (const id of ids) {
    if (!matchedBudget.expectedWorkloads.includes(id)) {
      errors.push(`${platform} report contains unexpected workload ${id ?? 'missing'}`);
    }
  }

  const soak = report.soak;
  if (!soak || soak.requestedSeconds !== expected.soakSeconds) {
    errors.push(`${platform} soak duration does not match profile`);
  } else {
    if (!finiteNumber(soak.elapsedSeconds) || soak.elapsedSeconds < Math.max(0.001, expected.soakSeconds * 0.95)) {
      errors.push(`${platform} soak ended before the requested duration`);
    }
    if (!Number.isSafeInteger(soak.iterations) || soak.iterations < 1) {
      errors.push(`${platform} soak did not complete an iteration`);
    }
    if (!Array.isArray(soak.samples) || soak.samples.length < 2) {
      errors.push(`${platform} soak has insufficient resource samples`);
    }
    for (const key of ['rssStartBytes', 'rssEndBytes', 'rssMaximumBytes']) {
      if (!finiteNumber(soak[key]) || soak[key] <= 0) errors.push(`${platform} soak ${key} is invalid`);
    }
    if (soak.rssGrowthBytes !== soak.rssEndBytes - soak.rssStartBytes) {
      errors.push(`${platform} soak RSS growth is internally inconsistent`);
    }
  }
  return byID;
}

export function compareMatchedPerformance({ macos, linux, budget, profile, expectedProvenance = null }) {
  const errors = [];
  const matchedBudget = budget?.matched;
  const expected = matchedBudget?.profiles?.[profile];
  if (!matchedBudget || !expected) {
    return { schemaVersion: 1, profile, pass: false, errors: [`unknown matched performance profile ${profile}`], workloads: [] };
  }

  const macRows = validateReport(macos, 'macos', expected, matchedBudget, errors, profile, expectedProvenance);
  const linuxRows = validateReport(linux, 'linux', expected, matchedBudget, errors, profile, expectedProvenance);
  for (const key of ["gitCommit", "packageVersion", "sourceDigest"]) {
    if (macos?.provenance?.[key] !== linux?.provenance?.[key]) errors.push(`matched report provenance ${key} differs between macOS and Linux`);
  }
  if (JSON.stringify(macos?.provenance?.candidate) !== JSON.stringify(linux?.provenance?.candidate)) {
    errors.push("matched report candidate provenance differs between macOS and Linux");
  }
  if (normalizedArchitecture(macos?.host?.architecture) !== normalizedArchitecture(linux?.host?.architecture)) {
    errors.push(`architecture mismatch: macos=${macos?.host?.architecture ?? 'missing'} linux=${linux?.host?.architecture ?? 'missing'}`);
  }

  const workloads = [];
  for (const id of matchedBudget.expectedWorkloads) {
    const mac = macRows.get(id);
    const lin = linuxRows.get(id);
    if (!mac || !lin) continue;
    if (mac.checksum !== lin.checksum) errors.push(`${id} checksum mismatch between macOS and Linux`);
    const absolute = matchedBudget.workloadThresholdsMs?.[id];
    if (!absolute) {
      errors.push(`budget is missing workload thresholds for ${id}`);
      continue;
    }
    const p95ParityLimit = Math.max(
      mac.percentiles.p95 * matchedBudget.linuxParity.p95Multiplier,
      mac.percentiles.p95 + matchedBudget.linuxParity.p95AdditiveFloorMs
    );
    const p99ParityLimit = Math.max(
      mac.percentiles.p99 * matchedBudget.linuxParity.p99Multiplier,
      mac.percentiles.p99 + matchedBudget.linuxParity.p99AdditiveFloorMs
    );
    const checks = {
      macP95Absolute: mac.percentiles.p95 <= absolute.p95,
      linuxP95Absolute: lin.percentiles.p95 <= absolute.p95,
      macP99Absolute: mac.percentiles.p99 <= absolute.p99,
      linuxP99Absolute: lin.percentiles.p99 <= absolute.p99,
      linuxP95Parity: lin.percentiles.p95 <= p95ParityLimit,
      linuxP99Parity: lin.percentiles.p99 <= p99ParityLimit,
      checksumMatch: mac.checksum === lin.checksum
    };
    for (const [check, passed] of Object.entries(checks)) {
      if (!passed) errors.push(`${id} failed ${check}`);
    }
    workloads.push({
      id,
      checksum: { macos: mac.checksum, linux: lin.checksum },
      macos: mac.percentiles,
      linux: lin.percentiles,
      limits: { absolute, linuxP95Parity: p95ParityLimit, linuxP99Parity: p99ParityLimit },
      checks,
      pass: Object.values(checks).every(Boolean)
    });
  }

  const resources = {};
  for (const [platform, report] of [['macos', macos], ['linux', linux]]) {
    const soak = report?.soak ?? {};
    const thresholds = matchedBudget.resourceThresholds;
    const checks = {
      maximumRss: finiteNumber(soak.rssMaximumBytes) && soak.rssMaximumBytes <= thresholds.maximumRssBytes,
      rssGrowth: finiteNumber(soak.rssGrowthBytes) && soak.rssGrowthBytes <= thresholds.maximumRssGrowthBytes,
      cpuUtilization: finiteNumber(soak.cpuUtilizationPercent) && soak.cpuUtilizationPercent <= thresholds.maximumCpuUtilizationPercent
    };
    for (const [check, passed] of Object.entries(checks)) {
      if (!passed) errors.push(`${platform} soak failed ${check}`);
    }
    resources[platform] = { ...soak, samples: undefined, checks, pass: Object.values(checks).every(Boolean) };
  }

  return {
    schemaVersion: 1,
    protocolVersion: matchedBudget.protocolVersion,
    generatedAt: new Date().toISOString(),
    profile,
    configuration: expected,
    hosts: { macos: macos?.host ?? null, linux: linux?.host ?? null },
    provenance: {
      gitCommit: macos?.provenance?.gitCommit ?? null,
      packageVersion: macos?.provenance?.packageVersion ?? null,
      sourceDigest: macos?.provenance?.sourceDigest ?? null,
      candidate: macos?.provenance?.candidate ?? null,
      macosProducedAt: macos?.provenance?.endedAt ?? null,
      linuxProducedAt: linux?.provenance?.endedAt ?? null,
    },
    workloads,
    resources,
    errors,
    pass: errors.length === 0
  };
}
