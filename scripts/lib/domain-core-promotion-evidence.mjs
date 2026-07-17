import {
  coverageKey,
  DOMAIN_CORE_REQUIRED_COVERAGE,
  isValidDomainSliceConsumer,
  runtimeDiagnosticCoverageForDomain,
} from "./domain-core-evidence-contract.mjs";

const WINDOW_KEYS = new Set([
  "consumer",
  "channel",
  "startedAt",
  "endedAt",
  "sampleCount",
  "mismatches",
  "latency",
]);
const MISMATCH_KEYS = new Set([
  "category",
  "count",
  "resolution",
  "issue",
  "reviewedBy",
  "approvedAt",
]);
const LATENCY_KEYS = new Set([
  "sampleCount",
  "legacyP95Micros",
  "rustP95Micros",
]);
const POLICY_KEYS = new Set(["schemaVersion", "domains"]);

const IDENTIFIER = /^[a-z][a-z0-9_.-]{0,63}$/u;
const VERSION =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;
const REVIEWER = /^@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/u;
const ISSUE =
  /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/(?:issues|pull)\/\d+$/u;
const UTC_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/u;
const GIT_REVISION = /^[0-9a-f]{40}$/u;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1_000;

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, allowed, path, errors) {
  if (!isRecord(value)) {
    errors.push(`${path} must be an object`);
    return false;
  }
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) errors.push(`${path}.${key} is not allowed`);
  }
  return true;
}

function safeInteger(value, path, errors, { positive = false } = {}) {
  if (!Number.isSafeInteger(value) || value < (positive ? 1 : 0)) {
    errors.push(
      `${path} must be a ${positive ? "positive" : "non-negative"} safe integer`,
    );
    return false;
  }
  return true;
}

function parseTimestamp(value, path, errors) {
  if (typeof value !== "string" || !UTC_TIMESTAMP.test(value)) {
    errors.push(`${path} must be an RFC 3339 UTC timestamp`);
    return null;
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    errors.push(`${path} must be a valid timestamp`);
    return null;
  }
  const canonical = value.includes(".")
    ? value.replace(
        /\.(\d{1,3})Z$/u,
        (_, fraction) => `.${fraction.padEnd(3, "0")}Z`,
      )
    : value.replace(/Z$/u, ".000Z");
  if (new Date(parsed).toISOString() !== canonical) {
    errors.push(`${path} must be a valid calendar timestamp`);
    return null;
  }
  return parsed;
}

function addBlocker(blockers, code, consumer = null, details = {}) {
  blockers.push({ code, consumer, ...details });
}

function isCanonicalVersion(value) {
  return typeof value === "string" && value.length <= 64 && VERSION.test(value);
}

const V3_ROOT_KEYS = new Set([
  "schemaVersion",
  "domain",
  "candidateCommit",
  "expectedCoreVersion",
  "expectedCoreAbiVersion",
  "expectedCoreSourceSha256",
  "generatedAt",
  "provenance",
  "windows",
]);
const V3_PROVENANCE_KEYS = new Set([
  "collector",
  "candidateCommit",
  "expectedCoreVersion",
  "expectedCoreAbiVersion",
  "expectedCoreSourceSha256",
  "sourceUri",
]);
const V3_WINDOW_KEYS = new Set([...WINDOW_KEYS, "slice", "dailySampleCounts"]);
const DAILY_SAMPLE_KEYS = new Set(["date", "sampleCount"]);
const V3_DOMAIN_POLICY_KEYS = new Set([
  "requiredCoverage",
  "allowedChannels",
  "minimumCoverageSeconds",
  "minimumSamples",
  "maximumP95RegressionBasisPoints",
]);
const COVERAGE_KEYS = new Set(["slice", "consumer"]);
const SHA256 = /^[0-9a-f]{64}$/u;
const UTC_DATE = /^\d{4}-\d{2}-\d{2}$/u;
const MAX_OBSERVATION_DAYS = 32;
const MAX_CORE_ABI_VERSION = 0xffff_ffff;
const HARD_MISMATCH_CATEGORIES = new Set([
  "native_unavailable",
  "native_error",
  "loaded_identity_mismatch",
]);
const DIAGNOSTIC_POLICY_KEYS = new Set([
  "schemaVersion",
  "authority",
  "promotionAuthority",
  "description",
  "domains",
]);
const DIAGNOSTIC_DOMAIN_KEYS = new Set([
  "requiredCoverage",
  "allowedChannels",
  "mismatchAlertCategories",
  "performanceAlertBasisPoints",
]);
const DIAGNOSTIC_MISMATCH_CATEGORIES = new Set([
  ...HARD_MISMATCH_CATEGORIES,
  "result_mismatch",
  "invalid_result",
]);

function invalidV3Report(domain, errors) {
  return {
    schemaVersion: 3,
    domain: typeof domain === "string" ? domain : null,
    status: "invalid",
    ready: false,
    errors,
    blockers: [{ code: "invalid_evidence", slice: null, consumer: null }],
  };
}

function diagnosticPolicy(policy) {
  const errors = [];
  if (!exactKeys(policy, DIAGNOSTIC_POLICY_KEYS, "policy", errors)) {
    return { errors, normalized: null };
  }
  for (const key of DIAGNOSTIC_POLICY_KEYS) {
    if (!Object.hasOwn(policy, key)) errors.push(`policy.${key} is required`);
  }
  if (policy.schemaVersion !== 1) errors.push("policy.schemaVersion must be 1");
  if (policy.authority !== "diagnostic-only") {
    errors.push("policy.authority must be diagnostic-only");
  }
  if (policy.promotionAuthority !== false) {
    errors.push("policy.promotionAuthority must be false");
  }
  if (typeof policy.description !== "string" || policy.description.length === 0) {
    errors.push("policy.description must be a non-empty string");
  }
  const requiredDomains = Object.keys(DOMAIN_CORE_REQUIRED_COVERAGE);
  if (!isRecord(policy.domains)) {
    errors.push("policy.domains must be an object");
    return { errors, normalized: null };
  }
  for (const domain of Object.keys(policy.domains)) {
    if (!requiredDomains.includes(domain)) {
      errors.push(`policy.domains contains unexpected ${domain}`);
    }
  }
  for (const domain of requiredDomains) {
    if (!Object.hasOwn(policy.domains, domain)) {
      errors.push(`policy.domains omits ${domain}`);
      continue;
    }
    const value = policy.domains[domain];
    const path = `policy.domains.${domain}`;
    if (!exactKeys(value, DIAGNOSTIC_DOMAIN_KEYS, path, errors)) continue;
    for (const key of DIAGNOSTIC_DOMAIN_KEYS) {
      if (!Object.hasOwn(value, key)) errors.push(`${path}.${key} is required`);
    }
    if (!Array.isArray(value.mismatchAlertCategories)) {
      errors.push(`${path}.mismatchAlertCategories must be an array`);
    } else {
      const categories = new Set(value.mismatchAlertCategories);
      if (categories.size !== value.mismatchAlertCategories.length) {
        errors.push(`${path}.mismatchAlertCategories must not contain duplicates`);
      }
      for (const category of DIAGNOSTIC_MISMATCH_CATEGORIES) {
        if (!categories.has(category)) {
          errors.push(`${path}.mismatchAlertCategories omits ${category}`);
        }
      }
      for (const category of categories) {
        if (!DIAGNOSTIC_MISMATCH_CATEGORIES.has(category)) {
          errors.push(`${path}.mismatchAlertCategories contains unexpected ${String(category)}`);
        }
      }
    }
    if (value.performanceAlertBasisPoints !== 500) {
      errors.push(`${path}.performanceAlertBasisPoints must be 500`);
    }
  }
  if (errors.length > 0) return { errors, normalized: null };
  return {
    errors,
    normalized: {
      schemaVersion: 2,
      domains: Object.fromEntries(
        requiredDomains.map((domain) => [
          domain,
          {
            requiredCoverage: policy.domains[domain].requiredCoverage,
            allowedChannels: policy.domains[domain].allowedChannels,
            minimumCoverageSeconds: 1,
            minimumSamples: 1,
            maximumP95RegressionBasisPoints:
              policy.domains[domain].performanceAlertBasisPoints,
          },
        ]),
      ),
    },
  };
}

function validateV3Policy(policy, errors) {
  if (!exactKeys(policy, POLICY_KEYS, "policy", errors)) return;
  if (policy.schemaVersion !== 2) errors.push("policy.schemaVersion must be 2");
  if (!isRecord(policy.domains) || Object.keys(policy.domains).length === 0) {
    errors.push("policy.domains must be a non-empty object");
    return;
  }
  for (const [domain, value] of Object.entries(policy.domains)) {
    const path = `policy.domains.${domain}`;
    if (!IDENTIFIER.test(domain))
      errors.push(`${path} has an invalid domain identifier`);
    if (!exactKeys(value, V3_DOMAIN_POLICY_KEYS, path, errors)) continue;
    if (
      !Array.isArray(value.requiredCoverage) ||
      value.requiredCoverage.length === 0
    ) {
      errors.push(`${path}.requiredCoverage must be a non-empty array`);
    } else {
      const seen = new Set();
      value.requiredCoverage.forEach((coverage, index) => {
        const coveragePath = `${path}.requiredCoverage[${index}]`;
        if (!exactKeys(coverage, COVERAGE_KEYS, coveragePath, errors)) return;
        if (
          typeof coverage.slice !== "string" ||
          !IDENTIFIER.test(coverage.slice)
        ) {
          errors.push(`${coveragePath}.slice must be a valid identifier`);
        }
        if (
          typeof coverage.consumer !== "string" ||
          !IDENTIFIER.test(coverage.consumer)
        ) {
          errors.push(`${coveragePath}.consumer must be a valid identifier`);
        }
        const key = coverageKey(coverage.slice, coverage.consumer);
        if (seen.has(key)) errors.push(`${coveragePath} duplicates ${key}`);
        seen.add(key);
        if (
          !isValidDomainSliceConsumer(domain, coverage.slice, coverage.consumer)
        ) {
          errors.push(`${coveragePath} is not a real ${domain} consumer`);
        }
      });
      const expected = new Set(
        runtimeDiagnosticCoverageForDomain(domain).map((item) =>
          coverageKey(item.slice, item.consumer),
        ),
      );
      for (const key of expected) {
        if (!seen.has(key))
          errors.push(`${path}.requiredCoverage omits real coverage ${key}`);
      }
      for (const key of seen) {
        if (!expected.has(key))
          errors.push(
            `${path}.requiredCoverage contains unexpected coverage ${key}`,
          );
      }
    }
    if (
      !Array.isArray(value.allowedChannels) ||
      value.allowedChannels.length === 0
    ) {
      errors.push(`${path}.allowedChannels must be a non-empty array`);
    } else {
      const unique = new Set();
      for (const channel of value.allowedChannels) {
        if (typeof channel !== "string" || !IDENTIFIER.test(channel)) {
          errors.push(`${path}.allowedChannels contains an invalid identifier`);
        } else if (unique.has(channel)) {
          errors.push(`${path}.allowedChannels contains duplicate ${channel}`);
        }
        unique.add(channel);
      }
    }
    safeInteger(
      value.minimumCoverageSeconds,
      `${path}.minimumCoverageSeconds`,
      errors,
      { positive: true },
    );
    safeInteger(value.minimumSamples, `${path}.minimumSamples`, errors, {
      positive: true,
    });
    safeInteger(
      value.maximumP95RegressionBasisPoints,
      `${path}.maximumP95RegressionBasisPoints`,
      errors,
    );
  }
}

function validateMismatch(mismatch, path, generatedAt, categories, errors) {
  if (!exactKeys(mismatch, MISMATCH_KEYS, path, errors)) return;
  if (
    typeof mismatch.category !== "string" ||
    !IDENTIFIER.test(mismatch.category)
  ) {
    errors.push(`${path}.category must be a valid identifier`);
  } else if (categories.has(mismatch.category)) {
    errors.push(`${path}.category duplicates ${mismatch.category}`);
  }
  categories.add(mismatch.category);
  safeInteger(mismatch.count, `${path}.count`, errors, { positive: true });
  if (
    mismatch.resolution !== "explained" &&
    mismatch.resolution !== "unexplained"
  ) {
    errors.push(`${path}.resolution must be explained or unexplained`);
    return;
  }
  if (
    mismatch.category === "loaded_identity_mismatch" &&
    mismatch.resolution !== "unexplained"
  ) {
    errors.push(`${path}.loaded_identity_mismatch cannot be explained away`);
  }
  if (mismatch.resolution === "explained") {
    if (typeof mismatch.issue !== "string" || !ISSUE.test(mismatch.issue)) {
      errors.push(`${path}.issue must be a GitHub issue or pull request URL`);
    }
    if (
      typeof mismatch.reviewedBy !== "string" ||
      !REVIEWER.test(mismatch.reviewedBy)
    ) {
      errors.push(`${path}.reviewedBy must be a GitHub handle`);
    }
    const approvedAt = parseTimestamp(
      mismatch.approvedAt,
      `${path}.approvedAt`,
      errors,
    );
    if (
      approvedAt !== null &&
      generatedAt !== null &&
      approvedAt > generatedAt
    ) {
      errors.push(
        `${path}.approvedAt must not be later than evidence.generatedAt`,
      );
    }
  } else {
    for (const field of ["issue", "reviewedBy", "approvedAt"]) {
      if (mismatch[field] !== undefined)
        errors.push(
          `${path}.${field} is only allowed for explained mismatches`,
        );
    }
  }
}

function validateCandidate(evidence, errors) {
  if (
    typeof evidence.candidateCommit !== "string" ||
    !GIT_REVISION.test(evidence.candidateCommit)
  ) {
    errors.push(
      "evidence.candidateCommit must be a full lowercase Git revision",
    );
  }
  if (!isCanonicalVersion(evidence.expectedCoreVersion)) {
    errors.push("evidence.expectedCoreVersion must be a semantic version");
  }
  if (
    !Number.isSafeInteger(evidence.expectedCoreAbiVersion) ||
    evidence.expectedCoreAbiVersion < 1 ||
    evidence.expectedCoreAbiVersion > MAX_CORE_ABI_VERSION
  ) {
    errors.push(
      "evidence.expectedCoreAbiVersion must be an unsigned 32-bit integer",
    );
  }
  if (
    typeof evidence.expectedCoreSourceSha256 !== "string" ||
    !SHA256.test(evidence.expectedCoreSourceSha256)
  ) {
    errors.push(
      "evidence.expectedCoreSourceSha256 must be a lowercase SHA-256 digest",
    );
  }
}

function validateV3Provenance(value, evidence, errors) {
  if (!exactKeys(value, V3_PROVENANCE_KEYS, "evidence.provenance", errors))
    return;
  if (
    typeof value.collector !== "string" ||
    !IDENTIFIER.test(value.collector)
  ) {
    errors.push("evidence.provenance.collector must be a valid identifier");
  }
  for (const field of [
    "candidateCommit",
    "expectedCoreVersion",
    "expectedCoreAbiVersion",
    "expectedCoreSourceSha256",
  ]) {
    if (value[field] !== evidence[field]) {
      errors.push(`evidence.provenance.${field} must match evidence.${field}`);
    }
  }
  try {
    const uri = new URL(value.sourceUri);
    if (
      uri.protocol !== "https:" ||
      uri.username !== "" ||
      uri.password !== "" ||
      uri.search !== "" ||
      uri.hash !== ""
    ) {
      throw new Error("invalid source URI");
    }
  } catch {
    errors.push(
      "evidence.provenance.sourceUri must be credential-free HTTPS without query or fragment",
    );
  }
}

function requiredUtcDays(startedAt, endedAt, path, errors) {
  const coverageMillis = endedAt - startedAt;
  if (coverageMillis <= 0) return [];
  if (coverageMillis > MAX_OBSERVATION_DAYS * 24 * 60 * 60 * 1_000) {
    errors.push(
      `${path} exceeds the maximum ${MAX_OBSERVATION_DAYS}-day observation window`,
    );
    return [];
  }
  const startDay = new Date(startedAt).toISOString().slice(0, 10);
  let cursor = Date.parse(`${startDay}T00:00:00.000Z`);
  const days = [];
  while (cursor < endedAt) {
    days.push(new Date(cursor).toISOString().slice(0, 10));
    cursor += 24 * 60 * 60 * 1_000;
  }
  return days;
}

function validateDailySampleCounts(
  value,
  path,
  startedAt,
  endedAt,
  sampleCount,
  errors,
) {
  if (!Array.isArray(value) || value.length === 0) {
    errors.push(`${path}.dailySampleCounts must be a non-empty array`);
    return;
  }
  if (startedAt === null || endedAt === null || endedAt <= startedAt) return;
  const requiredDays = requiredUtcDays(startedAt, endedAt, path, errors);
  const expected = new Set(requiredDays);
  const seen = new Set();
  let total = 0;
  value.forEach((entry, index) => {
    const entryPath = `${path}.dailySampleCounts[${index}]`;
    if (!exactKeys(entry, DAILY_SAMPLE_KEYS, entryPath, errors)) return;
    if (typeof entry.date !== "string" || !UTC_DATE.test(entry.date)) {
      errors.push(`${entryPath}.date must be a UTC calendar date`);
    } else {
      const parsed = Date.parse(`${entry.date}T00:00:00.000Z`);
      if (
        !Number.isFinite(parsed) ||
        new Date(parsed).toISOString().slice(0, 10) !== entry.date
      ) {
        errors.push(`${entryPath}.date must be a valid UTC calendar date`);
      }
      if (seen.has(entry.date))
        errors.push(`${entryPath}.date duplicates ${entry.date}`);
      if (!expected.has(entry.date))
        errors.push(`${entryPath}.date is outside the observation window`);
      seen.add(entry.date);
    }
    if (
      safeInteger(entry.sampleCount, `${entryPath}.sampleCount`, errors, {
        positive: true,
      })
    ) {
      total += entry.sampleCount;
    }
  });
  for (const day of requiredDays) {
    if (!seen.has(day))
      errors.push(`${path}.dailySampleCounts is missing UTC day ${day}`);
  }
  if (Number.isSafeInteger(sampleCount) && total !== sampleCount) {
    errors.push(`${path}.dailySampleCounts must sum to ${path}.sampleCount`);
  }
}

function evaluateV3PromotionEvidence(evidence, policy, options = {}) {
  const errors = [];
  validateV3Policy(policy, errors);
  if (!exactKeys(evidence, V3_ROOT_KEYS, "evidence", errors))
    return invalidV3Report(null, errors);
  if (evidence.schemaVersion !== 3)
    errors.push("evidence.schemaVersion must be 3");
  if (
    typeof evidence.domain !== "string" ||
    !IDENTIFIER.test(evidence.domain)
  ) {
    errors.push("evidence.domain must be a valid identifier");
  }
  validateCandidate(evidence, errors);
  validateV3Provenance(evidence.provenance, evidence, errors);
  const generatedAt = parseTimestamp(
    evidence.generatedAt,
    "evidence.generatedAt",
    errors,
  );
  if (!Array.isArray(evidence.windows) || evidence.windows.length === 0) {
    errors.push("evidence.windows must be a non-empty array");
  }
  const domainPolicy = isRecord(policy?.domains)
    ? policy.domains[evidence.domain]
    : null;
  if (!isRecord(domainPolicy))
    errors.push(`no promotion policy exists for domain ${evidence.domain}`);

  const now = options.now === undefined ? Date.now() : Date.parse(options.now);
  if (!Number.isFinite(now))
    errors.push("options.now must be a valid timestamp");
  if (
    generatedAt !== null &&
    Number.isFinite(now) &&
    generatedAt > now + MAX_CLOCK_SKEW_MS
  ) {
    errors.push(
      "evidence.generatedAt is in the future beyond the allowed clock skew",
    );
  }

  const seen = new Set();
  const normalized = [];
  if (Array.isArray(evidence.windows)) {
    evidence.windows.forEach((window, index) => {
      const path = `evidence.windows[${index}]`;
      if (!exactKeys(window, V3_WINDOW_KEYS, path, errors)) return;
      for (const field of ["slice", "consumer", "channel"]) {
        if (
          typeof window[field] !== "string" ||
          !IDENTIFIER.test(window[field])
        ) {
          errors.push(`${path}.${field} must be a valid identifier`);
        }
      }
      if (
        typeof evidence.domain === "string" &&
        typeof window.slice === "string" &&
        typeof window.consumer === "string" &&
        !isValidDomainSliceConsumer(
          evidence.domain,
          window.slice,
          window.consumer,
        )
      ) {
        errors.push(
          `${path} is not a valid ${evidence.domain} slice/consumer pair`,
        );
      }
      const key = coverageKey(window.slice, window.consumer);
      if (seen.has(key)) errors.push(`${path} duplicates coverage ${key}`);
      seen.add(key);
      const startedAt = parseTimestamp(
        window.startedAt,
        `${path}.startedAt`,
        errors,
      );
      const endedAt = parseTimestamp(window.endedAt, `${path}.endedAt`, errors);
      if (startedAt !== null && endedAt !== null && endedAt <= startedAt) {
        errors.push(`${path}.endedAt must be later than startedAt`);
      }
      if (endedAt !== null && generatedAt !== null && endedAt > generatedAt) {
        errors.push(
          `${path}.endedAt must not be later than evidence.generatedAt`,
        );
      }
      safeInteger(window.sampleCount, `${path}.sampleCount`, errors, {
        positive: true,
      });
      validateDailySampleCounts(
        window.dailySampleCounts,
        path,
        startedAt,
        endedAt,
        window.sampleCount,
        errors,
      );
      if (!Array.isArray(window.mismatches)) {
        errors.push(`${path}.mismatches must be an array`);
      } else {
        const categories = new Set();
        window.mismatches.forEach((mismatch, mismatchIndex) =>
          validateMismatch(
            mismatch,
            `${path}.mismatches[${mismatchIndex}]`,
            generatedAt,
            categories,
            errors,
          ),
        );
        if (
          Number.isSafeInteger(window.sampleCount) &&
          window.mismatches.every((mismatch) =>
            Number.isSafeInteger(mismatch?.count),
          )
        ) {
          const mismatchCount = window.mismatches.reduce(
            (sum, mismatch) => sum + BigInt(mismatch.count),
            0n,
          );
          if (mismatchCount > BigInt(window.sampleCount)) {
            errors.push(
              `${path}.mismatches count must not exceed ${path}.sampleCount`,
            );
          }
        }
      }
      if (exactKeys(window.latency, LATENCY_KEYS, `${path}.latency`, errors)) {
        safeInteger(
          window.latency.sampleCount,
          `${path}.latency.sampleCount`,
          errors,
          { positive: true },
        );
        safeInteger(
          window.latency.legacyP95Micros,
          `${path}.latency.legacyP95Micros`,
          errors,
          { positive: true },
        );
        safeInteger(
          window.latency.rustP95Micros,
          `${path}.latency.rustP95Micros`,
          errors,
        );
        if (
          Number.isSafeInteger(window.sampleCount) &&
          window.latency.sampleCount !== window.sampleCount
        ) {
          errors.push(
            `${path}.latency.sampleCount must equal ${path}.sampleCount`,
          );
        }
      }
      normalized.push({ ...window, startedAt, endedAt });
    });
  }
  if (normalized.length > 1) {
    const [first, ...rest] = normalized;
    for (const window of rest) {
      if (
        window.startedAt !== first.startedAt ||
        window.endedAt !== first.endedAt
      ) {
        errors.push(
          "all evidence windows must share one candidate observation window",
        );
        break;
      }
    }
  }
  if (errors.length > 0) return invalidV3Report(evidence.domain, errors);

  const blockers = [];
  const summaries = [];
  const required = new Set(
    domainPolicy.requiredCoverage.map((item) =>
      coverageKey(item.slice, item.consumer),
    ),
  );
  const allowedChannels = new Set(domainPolicy.allowedChannels);
  for (const item of domainPolicy.requiredCoverage) {
    const key = coverageKey(item.slice, item.consumer);
    if (!seen.has(key))
      addBlocker(blockers, "required_coverage_missing", item.consumer, {
        slice: item.slice,
      });
  }
  let totalSamples = 0;
  let unexplainedMismatchCount = 0;
  const calculationErrors = [];
  for (const window of normalized) {
    const key = coverageKey(window.slice, window.consumer);
    if (!required.has(key))
      addBlocker(blockers, "unexpected_coverage", window.consumer, {
        slice: window.slice,
      });
    if (!allowedChannels.has(window.channel)) {
      addBlocker(blockers, "channel_not_eligible", window.consumer, {
        slice: window.slice,
        channel: window.channel,
      });
    }
    const coverageSeconds = Math.floor(
      (window.endedAt - window.startedAt) / 1_000,
    );
    if (coverageSeconds < domainPolicy.minimumCoverageSeconds) {
      addBlocker(blockers, "insufficient_coverage", window.consumer, {
        slice: window.slice,
        actualSeconds: coverageSeconds,
        requiredSeconds: domainPolicy.minimumCoverageSeconds,
      });
    }
    totalSamples += window.sampleCount;
    const unexplainedBigInt = window.mismatches
      .filter((item) => item.resolution === "unexplained")
      .reduce((sum, item) => sum + BigInt(item.count), 0n);
    if (unexplainedBigInt > BigInt(Number.MAX_SAFE_INTEGER)) {
      calculationErrors.push(
        `${key} unexplained mismatch count exceeds safe range`,
      );
    }
    const unexplained = Number(unexplainedBigInt);
    unexplainedMismatchCount += unexplained;
    if (unexplained > 0) {
      addBlocker(blockers, "unexplained_mismatches", window.consumer, {
        slice: window.slice,
        count: unexplained,
      });
    }
    const hardMismatchBigInt = window.mismatches
      .filter((item) => HARD_MISMATCH_CATEGORIES.has(item.category))
      .reduce((sum, item) => sum + BigInt(item.count), 0n);
    if (hardMismatchBigInt > BigInt(Number.MAX_SAFE_INTEGER)) {
      calculationErrors.push(`${key} hard mismatch count exceeds safe range`);
    }
    const hardMismatchCount = Number(hardMismatchBigInt);
    if (hardMismatchCount > 0) {
      addBlocker(blockers, "hard_mismatches", window.consumer, {
        slice: window.slice,
        count: hardMismatchCount,
      });
    }
    const legacy = BigInt(window.latency.legacyP95Micros);
    const rust = BigInt(window.latency.rustP95Micros);
    const regression = ((rust - legacy) * 10_000n) / legacy;
    if (
      regression > BigInt(Number.MAX_SAFE_INTEGER) ||
      regression < BigInt(Number.MIN_SAFE_INTEGER)
    ) {
      calculationErrors.push(`${key} p95 regression exceeds safe report range`);
    }
    const regressionBasisPoints = Number(regression);
    if (
      rust * 10_000n >
      legacy * BigInt(10_000 + domainPolicy.maximumP95RegressionBasisPoints)
    ) {
      addBlocker(blockers, "p95_regression_exceeded", window.consumer, {
        slice: window.slice,
        actualBasisPoints: regressionBasisPoints,
        maximumBasisPoints: domainPolicy.maximumP95RegressionBasisPoints,
      });
    }
    summaries.push({
      slice: window.slice,
      consumer: window.consumer,
      channel: window.channel,
      coverageSeconds,
      sampleCount: window.sampleCount,
      unexplainedMismatchCount: unexplained,
      p95RegressionBasisPoints: regressionBasisPoints,
    });
  }
  if (!Number.isSafeInteger(totalSamples))
    calculationErrors.push("aggregate sample count exceeds safe integer range");
  if (!Number.isSafeInteger(unexplainedMismatchCount)) {
    calculationErrors.push(
      "aggregate unexplained mismatch count exceeds safe integer range",
    );
  }
  if (calculationErrors.length > 0)
    return invalidV3Report(evidence.domain, calculationErrors);
  if (totalSamples < domainPolicy.minimumSamples) {
    addBlocker(blockers, "insufficient_samples", null, {
      slice: null,
      actual: totalSamples,
      required: domainPolicy.minimumSamples,
    });
  }
  return {
    schemaVersion: 3,
    domain: evidence.domain,
    candidateCommit: evidence.candidateCommit,
    expectedCoreVersion: evidence.expectedCoreVersion,
    expectedCoreAbiVersion: evidence.expectedCoreAbiVersion,
    expectedCoreSourceSha256: evidence.expectedCoreSourceSha256,
    generatedAt: evidence.generatedAt,
    provenance: { ...evidence.provenance },
    status: blockers.length === 0 ? "ready" : "not_ready",
    ready: blockers.length === 0,
    policy: {
      minimumCoverageSeconds: domainPolicy.minimumCoverageSeconds,
      minimumSamples: domainPolicy.minimumSamples,
      maximumP95RegressionBasisPoints:
        domainPolicy.maximumP95RegressionBasisPoints,
      requiredCoverage: domainPolicy.requiredCoverage.map((item) => ({
        ...item,
      })),
      allowedChannels: [...domainPolicy.allowedChannels],
    },
    summary: { totalSamples, unexplainedMismatchCount, coverage: summaries },
    blockers,
  };
}

export function evaluatePromotionEvidence(evidence, policy, options = {}) {
  if (evidence?.schemaVersion === 1 || evidence?.schemaVersion === 2) {
    return {
      schemaVersion: 3,
      domain: typeof evidence.domain === "string" ? evidence.domain : null,
      generatedAt: evidence.generatedAt ?? null,
      status: "not_ready",
      ready: false,
      sourceSchemaVersion: evidence.schemaVersion,
      blockers: [
        { code: "evidence_schema_v3_required", slice: null, consumer: null },
      ],
    };
  }
  const diagnostic = diagnosticPolicy(policy);
  if (diagnostic.errors.length > 0) {
    return invalidV3Report(evidence?.domain, diagnostic.errors);
  }
  const report = evaluateV3PromotionEvidence(
    evidence,
    diagnostic.normalized,
    options,
  );
  if (report.status === "invalid") return report;
  return {
    ...report,
    status: "diagnostic",
    ready: false,
    authority: "diagnostic-only",
    policy: {
      authority: "diagnostic-only",
      promotionAuthority: false,
      performanceAlertBasisPoints:
        policy.domains[evidence.domain].performanceAlertBasisPoints,
      mismatchAlertCategories: [
        ...policy.domains[evidence.domain].mismatchAlertCategories,
      ],
      requiredCoverage: policy.domains[evidence.domain].requiredCoverage.map(
        (item) => ({ ...item }),
      ),
      allowedChannels: [...policy.domains[evidence.domain].allowedChannels],
    },
    blockers: [
      ...report.blockers,
      { code: "deterministic_proof_required", slice: null, consumer: null },
    ],
  };
}
