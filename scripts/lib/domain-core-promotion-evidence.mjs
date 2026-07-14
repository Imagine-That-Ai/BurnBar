const ROOT_KEYS = new Set([
  "schemaVersion",
  "domain",
  "coreVersion",
  "generatedAt",
  "provenance",
  "windows",
]);
const PROVENANCE_KEYS = new Set(["collector", "queryRevision", "sourceUri"]);
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
const DOMAIN_POLICY_KEYS = new Set([
  "requiredConsumers",
  "allowedChannels",
  "minimumCoverageSeconds",
  "minimumSamples",
  "maximumP95RegressionBasisPoints",
]);

const IDENTIFIER = /^[a-z][a-z0-9_.-]{0,63}$/u;
const VERSION = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/u;
const REVIEWER = /^@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/u;
const ISSUE = /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/(?:issues|pull)\/\d+$/u;
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
    errors.push(`${path} must be a ${positive ? "positive" : "non-negative"} safe integer`);
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
    ? value.replace(/\.(\d{1,3})Z$/u, (_, fraction) => `.${fraction.padEnd(3, "0")}Z`)
    : value.replace(/Z$/u, ".000Z");
  if (new Date(parsed).toISOString() !== canonical) {
    errors.push(`${path} must be a valid calendar timestamp`);
    return null;
  }
  return parsed;
}

function validateProvenance(value, errors) {
  if (!exactKeys(value, PROVENANCE_KEYS, "evidence.provenance", errors)) return;
  if (typeof value.collector !== "string" || !IDENTIFIER.test(value.collector)) {
    errors.push("evidence.provenance.collector must be a valid identifier");
  }
  if (typeof value.queryRevision !== "string" || !GIT_REVISION.test(value.queryRevision)) {
    errors.push("evidence.provenance.queryRevision must be a full lowercase Git revision");
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
      throw new Error("source URI must be credential-free HTTPS without query or fragment");
    }
  } catch {
    errors.push(
      "evidence.provenance.sourceUri must be credential-free HTTPS without query or fragment",
    );
  }
}

function validatePolicy(policy, errors) {
  if (!exactKeys(policy, POLICY_KEYS, "policy", errors)) return;
  if (policy.schemaVersion !== 1) errors.push("policy.schemaVersion must be 1");
  if (!isRecord(policy.domains) || Object.keys(policy.domains).length === 0) {
    errors.push("policy.domains must be a non-empty object");
    return;
  }
  for (const [domain, value] of Object.entries(policy.domains)) {
    const path = `policy.domains.${domain}`;
    if (!IDENTIFIER.test(domain)) errors.push(`${path} has an invalid domain identifier`);
    if (!exactKeys(value, DOMAIN_POLICY_KEYS, path, errors)) continue;
    for (const field of ["requiredConsumers", "allowedChannels"]) {
      if (!Array.isArray(value[field]) || value[field].length === 0) {
        errors.push(`${path}.${field} must be a non-empty array`);
        continue;
      }
      const unique = new Set();
      for (const entry of value[field]) {
        if (typeof entry !== "string" || !IDENTIFIER.test(entry)) {
          errors.push(`${path}.${field} contains an invalid identifier`);
        } else if (unique.has(entry)) {
          errors.push(`${path}.${field} contains duplicate ${entry}`);
        }
        unique.add(entry);
      }
    }
    safeInteger(value.minimumCoverageSeconds, `${path}.minimumCoverageSeconds`, errors, {
      positive: true,
    });
    safeInteger(value.minimumSamples, `${path}.minimumSamples`, errors, { positive: true });
    safeInteger(
      value.maximumP95RegressionBasisPoints,
      `${path}.maximumP95RegressionBasisPoints`,
      errors,
    );
  }
}

function invalidReport(domain, errors) {
  return {
    schemaVersion: 1,
    domain: typeof domain === "string" ? domain : null,
    status: "invalid",
    ready: false,
    errors,
    blockers: [{ code: "invalid_evidence", consumer: null }],
  };
}

function addBlocker(blockers, code, consumer = null, details = {}) {
  blockers.push({ code, consumer, ...details });
}

function evaluateV1PromotionEvidence(evidence, policy, options = {}) {
  const errors = [];
  validatePolicy(policy, errors);
  if (!exactKeys(evidence, ROOT_KEYS, "evidence", errors)) {
    return invalidReport(null, errors);
  }
  if (evidence.schemaVersion !== 1) errors.push("evidence.schemaVersion must be 1");
  if (typeof evidence.domain !== "string" || !IDENTIFIER.test(evidence.domain)) {
    errors.push("evidence.domain must be a valid identifier");
  }
  if (typeof evidence.coreVersion !== "string" || !VERSION.test(evidence.coreVersion)) {
    errors.push("evidence.coreVersion must be a semantic version");
  }
  validateProvenance(evidence.provenance, errors);
  const generatedAt = parseTimestamp(evidence.generatedAt, "evidence.generatedAt", errors);
  if (!Array.isArray(evidence.windows) || evidence.windows.length === 0) {
    errors.push("evidence.windows must be a non-empty array");
  }

  const domainPolicy = isRecord(policy?.domains) ? policy.domains[evidence.domain] : null;
  if (!isRecord(domainPolicy)) errors.push(`no promotion policy exists for domain ${evidence.domain}`);

  const now = options.now === undefined ? Date.now() : Date.parse(options.now);
  if (!Number.isFinite(now)) errors.push("options.now must be a valid timestamp");
  if (generatedAt !== null && Number.isFinite(now) && generatedAt > now + MAX_CLOCK_SKEW_MS) {
    errors.push("evidence.generatedAt is in the future beyond the allowed clock skew");
  }

  const seenConsumers = new Set();
  const normalized = [];
  if (Array.isArray(evidence.windows)) {
    evidence.windows.forEach((window, index) => {
      const path = `evidence.windows[${index}]`;
      if (!exactKeys(window, WINDOW_KEYS, path, errors)) return;
      if (typeof window.consumer !== "string" || !IDENTIFIER.test(window.consumer)) {
        errors.push(`${path}.consumer must be a valid identifier`);
      } else if (seenConsumers.has(window.consumer)) {
        errors.push(`${path}.consumer duplicates ${window.consumer}`);
      }
      seenConsumers.add(window.consumer);
      if (typeof window.channel !== "string" || !IDENTIFIER.test(window.channel)) {
        errors.push(`${path}.channel must be a valid identifier`);
      }
      const startedAt = parseTimestamp(window.startedAt, `${path}.startedAt`, errors);
      const endedAt = parseTimestamp(window.endedAt, `${path}.endedAt`, errors);
      if (startedAt !== null && endedAt !== null && endedAt <= startedAt) {
        errors.push(`${path}.endedAt must be later than startedAt`);
      }
      if (endedAt !== null && generatedAt !== null && endedAt > generatedAt) {
        errors.push(`${path}.endedAt must not be later than evidence.generatedAt`);
      }
      safeInteger(window.sampleCount, `${path}.sampleCount`, errors, { positive: true });

      if (!Array.isArray(window.mismatches)) {
        errors.push(`${path}.mismatches must be an array`);
      } else {
        const categories = new Set();
        window.mismatches.forEach((mismatch, mismatchIndex) => {
          const mismatchPath = `${path}.mismatches[${mismatchIndex}]`;
          if (!exactKeys(mismatch, MISMATCH_KEYS, mismatchPath, errors)) return;
          if (typeof mismatch.category !== "string" || !IDENTIFIER.test(mismatch.category)) {
            errors.push(`${mismatchPath}.category must be a valid identifier`);
          } else if (categories.has(mismatch.category)) {
            errors.push(`${mismatchPath}.category duplicates ${mismatch.category}`);
          }
          categories.add(mismatch.category);
          safeInteger(mismatch.count, `${mismatchPath}.count`, errors, { positive: true });
          if (!new Set(["explained", "unexplained"]).has(mismatch.resolution)) {
            errors.push(`${mismatchPath}.resolution must be explained or unexplained`);
          }
          if (mismatch.resolution === "explained") {
            if (typeof mismatch.issue !== "string" || !ISSUE.test(mismatch.issue)) {
              errors.push(`${mismatchPath}.issue must be a GitHub issue or pull request URL`);
            }
            if (typeof mismatch.reviewedBy !== "string" || !REVIEWER.test(mismatch.reviewedBy)) {
              errors.push(`${mismatchPath}.reviewedBy must be a GitHub handle`);
            }
            const approvedAt = parseTimestamp(
              mismatch.approvedAt,
              `${mismatchPath}.approvedAt`,
              errors,
            );
            if (approvedAt !== null && generatedAt !== null && approvedAt > generatedAt) {
              errors.push(`${mismatchPath}.approvedAt must not be later than evidence.generatedAt`);
            }
          } else {
            for (const field of ["issue", "reviewedBy", "approvedAt"]) {
              if (mismatch[field] !== undefined) {
                errors.push(`${mismatchPath}.${field} is only allowed for explained mismatches`);
              }
            }
          }
        });
      }

      if (exactKeys(window.latency, LATENCY_KEYS, `${path}.latency`, errors)) {
        safeInteger(window.latency.sampleCount, `${path}.latency.sampleCount`, errors, {
          positive: true,
        });
        safeInteger(window.latency.legacyP95Micros, `${path}.latency.legacyP95Micros`, errors, {
          positive: true,
        });
        safeInteger(window.latency.rustP95Micros, `${path}.latency.rustP95Micros`, errors);
        if (
          Number.isSafeInteger(window.sampleCount) &&
          window.latency.sampleCount !== window.sampleCount
        ) {
          errors.push(`${path}.latency.sampleCount must equal ${path}.sampleCount`);
        }
      }

      normalized.push({ ...window, startedAt, endedAt });
    });
  }

  if (errors.length > 0) return invalidReport(evidence.domain, errors);

  const blockers = [];
  const summaries = [];
  const requiredConsumers = new Set(domainPolicy.requiredConsumers);
  const allowedChannels = new Set(domainPolicy.allowedChannels);
  let totalSamples = 0;
  let unexplainedMismatchCount = 0;
  const calculationErrors = [];

  for (const consumer of requiredConsumers) {
    if (!seenConsumers.has(consumer)) addBlocker(blockers, "required_consumer_missing", consumer);
  }
  for (const window of normalized) {
    if (!requiredConsumers.has(window.consumer)) {
      addBlocker(blockers, "unexpected_consumer", window.consumer);
    }
    if (!allowedChannels.has(window.channel)) {
      addBlocker(blockers, "channel_not_eligible", window.consumer, { channel: window.channel });
    }
    const coverageSeconds = Math.floor((window.endedAt - window.startedAt) / 1_000);
    if (coverageSeconds < domainPolicy.minimumCoverageSeconds) {
      addBlocker(blockers, "insufficient_coverage", window.consumer, {
        actualSeconds: coverageSeconds,
        requiredSeconds: domainPolicy.minimumCoverageSeconds,
      });
    }
    totalSamples += window.sampleCount;
    const consumerUnexplainedBigInt = window.mismatches
      .filter((item) => item.resolution === "unexplained")
      .reduce((sum, item) => sum + BigInt(item.count), 0n);
    if (consumerUnexplainedBigInt > BigInt(Number.MAX_SAFE_INTEGER)) {
      calculationErrors.push(`${window.consumer} unexplained mismatch count exceeds safe range`);
    }
    const consumerUnexplained = Number(consumerUnexplainedBigInt);
    unexplainedMismatchCount += consumerUnexplained;
    if (consumerUnexplained > 0) {
      addBlocker(blockers, "unexplained_mismatches", window.consumer, {
        count: consumerUnexplained,
      });
    }

    const legacy = BigInt(window.latency.legacyP95Micros);
    const rust = BigInt(window.latency.rustP95Micros);
    const limit = legacy * BigInt(10_000 + domainPolicy.maximumP95RegressionBasisPoints);
    const observed = rust * 10_000n;
    const regressionBasisPointsBigInt = ((rust - legacy) * 10_000n) / legacy;
    if (
      regressionBasisPointsBigInt > BigInt(Number.MAX_SAFE_INTEGER) ||
      regressionBasisPointsBigInt < BigInt(Number.MIN_SAFE_INTEGER)
    ) {
      calculationErrors.push(`${window.consumer} p95 regression exceeds safe report range`);
    }
    const regressionBasisPoints = Number(regressionBasisPointsBigInt);
    if (observed > limit) {
      addBlocker(blockers, "p95_regression_exceeded", window.consumer, {
        actualBasisPoints: regressionBasisPoints,
        maximumBasisPoints: domainPolicy.maximumP95RegressionBasisPoints,
      });
    }
    summaries.push({
      consumer: window.consumer,
      channel: window.channel,
      coverageSeconds,
      sampleCount: window.sampleCount,
      unexplainedMismatchCount: consumerUnexplained,
      p95RegressionBasisPoints: regressionBasisPoints,
    });
  }
  if (!Number.isSafeInteger(totalSamples)) {
    return invalidReport(evidence.domain, ["aggregate sample count exceeds safe integer range"]);
  }
  if (!Number.isSafeInteger(unexplainedMismatchCount)) {
    calculationErrors.push("aggregate unexplained mismatch count exceeds safe integer range");
  }
  if (calculationErrors.length > 0) return invalidReport(evidence.domain, calculationErrors);
  if (totalSamples < domainPolicy.minimumSamples) {
    addBlocker(blockers, "insufficient_samples", null, {
      actual: totalSamples,
      required: domainPolicy.minimumSamples,
    });
  }

  return {
    schemaVersion: 1,
    domain: evidence.domain,
    coreVersion: evidence.coreVersion,
    generatedAt: evidence.generatedAt,
    status: blockers.length === 0 ? "ready" : "not_ready",
    ready: blockers.length === 0,
    policy: {
      minimumCoverageSeconds: domainPolicy.minimumCoverageSeconds,
      minimumSamples: domainPolicy.minimumSamples,
      maximumP95RegressionBasisPoints: domainPolicy.maximumP95RegressionBasisPoints,
      requiredConsumers: [...domainPolicy.requiredConsumers],
      allowedChannels: [...domainPolicy.allowedChannels],
    },
    summary: { totalSamples, unexplainedMismatchCount, consumers: summaries },
    blockers,
  };
}

const V2_WINDOW_KEYS = new Set([...WINDOW_KEYS, "slice"]);
const V2_DOMAIN_POLICY_KEYS = new Set([
  "requiredCoverage",
  "allowedChannels",
  "minimumCoverageSeconds",
  "minimumSamples",
  "maximumP95RegressionBasisPoints",
]);
const COVERAGE_KEYS = new Set(["slice", "consumer"]);

function invalidV2Report(domain, errors) {
  return {
    schemaVersion: 2,
    domain: typeof domain === "string" ? domain : null,
    status: "invalid",
    ready: false,
    errors,
    blockers: [{ code: "invalid_evidence", slice: null, consumer: null }],
  };
}

function validateV2Policy(policy, errors) {
  if (!exactKeys(policy, POLICY_KEYS, "policy", errors)) return;
  if (policy.schemaVersion !== 2) errors.push("policy.schemaVersion must be 2");
  if (!isRecord(policy.domains) || Object.keys(policy.domains).length === 0) {
    errors.push("policy.domains must be a non-empty object");
    return;
  }
  for (const [domain, value] of Object.entries(policy.domains)) {
    const path = `policy.domains.${domain}`;
    if (!IDENTIFIER.test(domain)) errors.push(`${path} has an invalid domain identifier`);
    if (!exactKeys(value, V2_DOMAIN_POLICY_KEYS, path, errors)) continue;
    if (!Array.isArray(value.requiredCoverage) || value.requiredCoverage.length === 0) {
      errors.push(`${path}.requiredCoverage must be a non-empty array`);
    } else {
      const seen = new Set();
      value.requiredCoverage.forEach((coverage, index) => {
        const coveragePath = `${path}.requiredCoverage[${index}]`;
        if (!exactKeys(coverage, COVERAGE_KEYS, coveragePath, errors)) return;
        if (typeof coverage.slice !== "string" || !IDENTIFIER.test(coverage.slice)) {
          errors.push(`${coveragePath}.slice must be a valid identifier`);
        }
        if (typeof coverage.consumer !== "string" || !IDENTIFIER.test(coverage.consumer)) {
          errors.push(`${coveragePath}.consumer must be a valid identifier`);
        }
        const key = coverageKey(coverage.slice, coverage.consumer);
        if (seen.has(key)) errors.push(`${coveragePath} duplicates ${key}`);
        seen.add(key);
        if (!isValidDomainSliceConsumer(domain, coverage.slice, coverage.consumer)) {
          errors.push(`${coveragePath} is not a real ${domain} consumer`);
        }
      });
      const expected = new Set(requiredCoverageForDomain(domain).map((item) => coverageKey(item.slice, item.consumer)));
      for (const key of expected) {
        if (!seen.has(key)) errors.push(`${path}.requiredCoverage omits real coverage ${key}`);
      }
      for (const key of seen) {
        if (!expected.has(key)) errors.push(`${path}.requiredCoverage contains unexpected coverage ${key}`);
      }
    }
    if (!Array.isArray(value.allowedChannels) || value.allowedChannels.length === 0) {
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
    safeInteger(value.minimumCoverageSeconds, `${path}.minimumCoverageSeconds`, errors, { positive: true });
    safeInteger(value.minimumSamples, `${path}.minimumSamples`, errors, { positive: true });
    safeInteger(
      value.maximumP95RegressionBasisPoints,
      `${path}.maximumP95RegressionBasisPoints`,
      errors,
    );
  }
}

function validateMismatch(mismatch, path, generatedAt, categories, errors) {
  if (!exactKeys(mismatch, MISMATCH_KEYS, path, errors)) return;
  if (typeof mismatch.category !== "string" || !IDENTIFIER.test(mismatch.category)) {
    errors.push(`${path}.category must be a valid identifier`);
  } else if (categories.has(mismatch.category)) {
    errors.push(`${path}.category duplicates ${mismatch.category}`);
  }
  categories.add(mismatch.category);
  safeInteger(mismatch.count, `${path}.count`, errors, { positive: true });
  if (mismatch.resolution !== "explained" && mismatch.resolution !== "unexplained") {
    errors.push(`${path}.resolution must be explained or unexplained`);
    return;
  }
  if (mismatch.resolution === "explained") {
    if (typeof mismatch.issue !== "string" || !ISSUE.test(mismatch.issue)) {
      errors.push(`${path}.issue must be a GitHub issue or pull request URL`);
    }
    if (typeof mismatch.reviewedBy !== "string" || !REVIEWER.test(mismatch.reviewedBy)) {
      errors.push(`${path}.reviewedBy must be a GitHub handle`);
    }
    const approvedAt = parseTimestamp(mismatch.approvedAt, `${path}.approvedAt`, errors);
    if (approvedAt !== null && generatedAt !== null && approvedAt > generatedAt) {
      errors.push(`${path}.approvedAt must not be later than evidence.generatedAt`);
    }
  } else {
    for (const field of ["issue", "reviewedBy", "approvedAt"]) {
      if (mismatch[field] !== undefined) errors.push(`${path}.${field} is only allowed for explained mismatches`);
    }
  }
}

function evaluateV2PromotionEvidence(evidence, policy, options = {}) {
  const errors = [];
  validateV2Policy(policy, errors);
  if (!exactKeys(evidence, ROOT_KEYS, "evidence", errors)) return invalidV2Report(null, errors);
  if (evidence.schemaVersion !== 2) errors.push("evidence.schemaVersion must be 2");
  if (typeof evidence.domain !== "string" || !IDENTIFIER.test(evidence.domain)) {
    errors.push("evidence.domain must be a valid identifier");
  }
  if (typeof evidence.coreVersion !== "string" || !VERSION.test(evidence.coreVersion)) {
    errors.push("evidence.coreVersion must be a semantic version");
  }
  validateProvenance(evidence.provenance, errors);
  const generatedAt = parseTimestamp(evidence.generatedAt, "evidence.generatedAt", errors);
  if (!Array.isArray(evidence.windows) || evidence.windows.length === 0) {
    errors.push("evidence.windows must be a non-empty array");
  }
  const domainPolicy = isRecord(policy?.domains) ? policy.domains[evidence.domain] : null;
  if (!isRecord(domainPolicy)) errors.push(`no promotion policy exists for domain ${evidence.domain}`);

  const now = options.now === undefined ? Date.now() : Date.parse(options.now);
  if (!Number.isFinite(now)) errors.push("options.now must be a valid timestamp");
  if (generatedAt !== null && Number.isFinite(now) && generatedAt > now + MAX_CLOCK_SKEW_MS) {
    errors.push("evidence.generatedAt is in the future beyond the allowed clock skew");
  }

  const seen = new Set();
  const normalized = [];
  if (Array.isArray(evidence.windows)) {
    evidence.windows.forEach((window, index) => {
      const path = `evidence.windows[${index}]`;
      if (!exactKeys(window, V2_WINDOW_KEYS, path, errors)) return;
      for (const field of ["slice", "consumer", "channel"]) {
        if (typeof window[field] !== "string" || !IDENTIFIER.test(window[field])) {
          errors.push(`${path}.${field} must be a valid identifier`);
        }
      }
      if (
        typeof evidence.domain === "string" &&
        typeof window.slice === "string" &&
        typeof window.consumer === "string" &&
        !isValidDomainSliceConsumer(evidence.domain, window.slice, window.consumer)
      ) {
        errors.push(`${path} is not a valid ${evidence.domain} slice/consumer pair`);
      }
      const key = coverageKey(window.slice, window.consumer);
      if (seen.has(key)) errors.push(`${path} duplicates coverage ${key}`);
      seen.add(key);
      const startedAt = parseTimestamp(window.startedAt, `${path}.startedAt`, errors);
      const endedAt = parseTimestamp(window.endedAt, `${path}.endedAt`, errors);
      if (startedAt !== null && endedAt !== null && endedAt <= startedAt) {
        errors.push(`${path}.endedAt must be later than startedAt`);
      }
      if (endedAt !== null && generatedAt !== null && endedAt > generatedAt) {
        errors.push(`${path}.endedAt must not be later than evidence.generatedAt`);
      }
      safeInteger(window.sampleCount, `${path}.sampleCount`, errors, { positive: true });
      if (!Array.isArray(window.mismatches)) {
        errors.push(`${path}.mismatches must be an array`);
      } else {
        const categories = new Set();
        window.mismatches.forEach((mismatch, mismatchIndex) =>
          validateMismatch(mismatch, `${path}.mismatches[${mismatchIndex}]`, generatedAt, categories, errors),
        );
      }
      if (exactKeys(window.latency, LATENCY_KEYS, `${path}.latency`, errors)) {
        safeInteger(window.latency.sampleCount, `${path}.latency.sampleCount`, errors, { positive: true });
        safeInteger(window.latency.legacyP95Micros, `${path}.latency.legacyP95Micros`, errors, { positive: true });
        safeInteger(window.latency.rustP95Micros, `${path}.latency.rustP95Micros`, errors);
        if (Number.isSafeInteger(window.sampleCount) && window.latency.sampleCount !== window.sampleCount) {
          errors.push(`${path}.latency.sampleCount must equal ${path}.sampleCount`);
        }
      }
      normalized.push({ ...window, startedAt, endedAt });
    });
  }
  if (errors.length > 0) return invalidV2Report(evidence.domain, errors);

  const blockers = [];
  const summaries = [];
  const required = new Set(domainPolicy.requiredCoverage.map((item) => coverageKey(item.slice, item.consumer)));
  const allowedChannels = new Set(domainPolicy.allowedChannels);
  for (const item of domainPolicy.requiredCoverage) {
    const key = coverageKey(item.slice, item.consumer);
    if (!seen.has(key)) addBlocker(blockers, "required_coverage_missing", item.consumer, { slice: item.slice });
  }
  let totalSamples = 0;
  let unexplainedMismatchCount = 0;
  const calculationErrors = [];
  for (const window of normalized) {
    const key = coverageKey(window.slice, window.consumer);
    if (!required.has(key)) addBlocker(blockers, "unexpected_coverage", window.consumer, { slice: window.slice });
    if (!allowedChannels.has(window.channel)) {
      addBlocker(blockers, "channel_not_eligible", window.consumer, { slice: window.slice, channel: window.channel });
    }
    const coverageSeconds = Math.floor((window.endedAt - window.startedAt) / 1_000);
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
      calculationErrors.push(`${key} unexplained mismatch count exceeds safe range`);
    }
    const unexplained = Number(unexplainedBigInt);
    unexplainedMismatchCount += unexplained;
    if (unexplained > 0) {
      addBlocker(blockers, "unexplained_mismatches", window.consumer, { slice: window.slice, count: unexplained });
    }
    const legacy = BigInt(window.latency.legacyP95Micros);
    const rust = BigInt(window.latency.rustP95Micros);
    const regression = ((rust - legacy) * 10_000n) / legacy;
    if (regression > BigInt(Number.MAX_SAFE_INTEGER) || regression < BigInt(Number.MIN_SAFE_INTEGER)) {
      calculationErrors.push(`${key} p95 regression exceeds safe report range`);
    }
    const regressionBasisPoints = Number(regression);
    if (rust * 10_000n > legacy * BigInt(10_000 + domainPolicy.maximumP95RegressionBasisPoints)) {
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
      startedAt: new Date(window.startedAt).toISOString(),
      endedAt: new Date(window.endedAt).toISOString(),
      coverageSeconds,
      sampleCount: window.sampleCount,
      unexplainedMismatchCount: unexplained,
      p95RegressionBasisPoints: regressionBasisPoints,
    });
  }
  if (!Number.isSafeInteger(totalSamples)) calculationErrors.push("aggregate sample count exceeds safe integer range");
  if (!Number.isSafeInteger(unexplainedMismatchCount)) {
    calculationErrors.push("aggregate unexplained mismatch count exceeds safe integer range");
  }
  if (calculationErrors.length > 0) return invalidV2Report(evidence.domain, calculationErrors);
  if (totalSamples < domainPolicy.minimumSamples) {
    addBlocker(blockers, "insufficient_samples", null, { slice: null, actual: totalSamples, required: domainPolicy.minimumSamples });
  }
  return {
    schemaVersion: 2,
    domain: evidence.domain,
    coreVersion: evidence.coreVersion,
    generatedAt: evidence.generatedAt,
    provenance: { ...evidence.provenance },
    status: blockers.length === 0 ? "ready" : "not_ready",
    ready: blockers.length === 0,
    policy: {
      minimumCoverageSeconds: domainPolicy.minimumCoverageSeconds,
      minimumSamples: domainPolicy.minimumSamples,
      maximumP95RegressionBasisPoints: domainPolicy.maximumP95RegressionBasisPoints,
      requiredCoverage: domainPolicy.requiredCoverage.map((item) => ({ ...item })),
      allowedChannels: [...domainPolicy.allowedChannels],
    },
    summary: { totalSamples, unexplainedMismatchCount, coverage: summaries },
    blockers,
  };
}

export function evaluatePromotionEvidence(evidence, policy, options = {}) {
  if (evidence?.schemaVersion === 1 && policy?.schemaVersion === 1) {
    return evaluateV1PromotionEvidence(evidence, policy, options);
  }
  if (evidence?.schemaVersion === 1 && policy?.schemaVersion === 2) {
    const legacyErrors = [];
    exactKeys(evidence, ROOT_KEYS, "evidence", legacyErrors);
    if (typeof evidence.domain !== "string" || !IDENTIFIER.test(evidence.domain)) {
      legacyErrors.push("evidence.domain must be a valid identifier");
    }
    if (!Array.isArray(evidence.windows) || evidence.windows.length === 0) {
      legacyErrors.push("evidence.windows must be a non-empty array");
    }
    if (legacyErrors.length > 0) return invalidV2Report(evidence?.domain, legacyErrors);
    return {
      schemaVersion: 2,
      domain: evidence.domain,
      coreVersion: evidence.coreVersion ?? null,
      generatedAt: evidence.generatedAt ?? null,
      status: "not_ready",
      ready: false,
      sourceSchemaVersion: 1,
      blockers: [{ code: "evidence_schema_v2_required", slice: null, consumer: null }],
    };
  }
  return evaluateV2PromotionEvidence(evidence, policy, options);
}
import {
  coverageKey,
  isValidDomainSliceConsumer,
  requiredCoverageForDomain,
} from "./domain-core-evidence-contract.mjs";
