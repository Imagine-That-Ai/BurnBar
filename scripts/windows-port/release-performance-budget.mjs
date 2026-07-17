#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const PERFORMANCE_BUDGET_PATH = fileURLToPath(
  new URL("./release-performance-budgets.json", import.meta.url),
);
const performanceBudgetBytes = readFileSync(PERFORMANCE_BUDGET_PATH);
export const PERFORMANCE_BUDGET_SHA256 = createHash("sha256")
  .update(performanceBudgetBytes)
  .digest("hex");
export const PERFORMANCE_BUDGET_CATALOG = JSON.parse(performanceBudgetBytes.toString("utf8"));
export const PERFORMANCE_BUDGET_SCHEMA =
  "openburnbar.windows.release-performance-budgets.v1";
export const PERFORMANCE_BUDGET_STATUS = "ACTIVE_RELEASE_GATE";

const DIRECTIONS = new Set(["at_most", "at_least", "equal"]);
const STATISTICS = new Set(["p95", "average", "maximum", "rate", "growth", "count"]);

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

export function validatePerformanceBudgetCatalog(catalog = PERFORMANCE_BUDGET_CATALOG) {
  const errors = [];
  if (!isRecord(catalog) || catalog.schema !== PERFORMANCE_BUDGET_SCHEMA) {
    return ["performance budget catalog schema is invalid"];
  }
  if (catalog.status !== PERFORMANCE_BUDGET_STATUS) {
    errors.push(`performance budget catalog status must be ${PERFORMANCE_BUDGET_STATUS}`);
  }
  if (catalog.profile !== "physical-performance") {
    errors.push("performance budget catalog profile must be physical-performance");
  }
  if (!Number.isInteger(catalog.revision) || catalog.revision < 1) {
    errors.push("performance budget catalog revision must be a positive integer");
  }
  if (
    !Number.isInteger(catalog.maximumSamplesPerMeasurement) ||
    catalog.maximumSamplesPerMeasurement < 1
  ) {
    errors.push("performance budget maximumSamplesPerMeasurement must be a positive integer");
  }
  const ids = new Set();
  for (const [index, measurement] of asArray(catalog.measurements).entries()) {
    const label = `performance budget measurements[${index}]`;
    if (!isRecord(measurement)) {
      errors.push(`${label} must be an object`);
      continue;
    }
    for (const field of ["id", "assertionId", "metric", "unit", "statistic", "direction"]) {
      if (typeof measurement[field] !== "string" || measurement[field].trim().length === 0) {
        errors.push(`${label}.${field} is required`);
      }
    }
    if (ids.has(measurement.id)) errors.push(`${label}.id is duplicated: ${measurement.id}`);
    ids.add(measurement.id);
    if (!DIRECTIONS.has(measurement.direction)) {
      errors.push(`${label}.direction is invalid`);
    }
    if (!STATISTICS.has(measurement.statistic)) {
      errors.push(`${label}.statistic is invalid`);
    }
    if (!finiteNumber(measurement.limit)) errors.push(`${label}.limit must be finite`);
    if (!Number.isInteger(measurement.minimumSamples) || measurement.minimumSamples < 1) {
      errors.push(`${label}.minimumSamples must be a positive integer`);
    }
    if (!finiteNumber(measurement.minimumDurationSeconds) || measurement.minimumDurationSeconds < 0) {
      errors.push(`${label}.minimumDurationSeconds must be a non-negative number`);
    }
  }
  if (ids.size === 0) errors.push("performance budget catalog has no measurements");
  for (const statistic of STATISTICS) {
    if (
      typeof catalog.calculationContract?.[statistic] !== "string" ||
      catalog.calculationContract[statistic].trim().length === 0
    ) {
      errors.push(`performance budget calculationContract.${statistic} is required`);
    }
  }
  const contextFields = asArray(catalog.requiredContext);
  if (contextFields.length === 0 || new Set(contextFields).size !== contextFields.length) {
    errors.push("performance budget requiredContext must contain unique fields");
  }
  for (const field of contextFields) {
    if (typeof field !== "string" || !/^[a-z][A-Za-z0-9]*$/.test(field)) {
      errors.push("performance budget requiredContext contains an invalid field");
    }
  }
  return [...new Set(errors)];
}

export function performanceContextTemplate() {
  return Object.fromEntries(
    PERFORMANCE_BUDGET_CATALOG.requiredContext.map((field) => [field, ""]),
  );
}

export function validatePerformanceContext(context, options = {}) {
  const label = options.label ?? "performance context";
  if (!isRecord(context)) return [`${label} is required`];
  const errors = [];
  for (const field of PERFORMANCE_BUDGET_CATALOG.requiredContext) {
    if (typeof context[field] !== "string" || context[field].trim().length === 0) {
      errors.push(`${label}.${field} is required`);
    }
  }
  return errors;
}

export function performanceMeasurementTemplate() {
  return PERFORMANCE_BUDGET_CATALOG.measurements.map((measurement) => ({
    id: measurement.id,
    assertionId: measurement.assertionId,
    unit: measurement.unit,
    statistic: measurement.statistic,
    direction: measurement.direction,
    limit: measurement.limit,
    minimumSamples: measurement.minimumSamples,
    minimumDurationSeconds: measurement.minimumDurationSeconds,
    value: null,
    sampleCount: 0,
    samples: [],
    durationSeconds: 0,
    context: "",
    evidenceFiles: [],
  }));
}

function passesBudget(value, budget) {
  if (budget.direction === "at_most") return value <= budget.limit;
  if (budget.direction === "at_least") return value >= budget.limit;
  return value === budget.limit;
}

export function derivePerformanceValue(samples, statistic) {
  if (!Array.isArray(samples) || samples.length === 0) {
    throw new Error("samples must contain at least one value");
  }
  if (!samples.every(finiteNumber)) throw new Error("samples must contain only finite numbers");
  if (samples.some((value) => value < 0)) {
    throw new Error("samples must be non-negative");
  }
  if (statistic === "p95") {
    const sorted = [...samples].sort((left, right) => left - right);
    return sorted[Math.max(0, Math.ceil(sorted.length * 0.95) - 1)];
  }
  if (statistic === "average") {
    return samples.reduce((sum, value) => sum + value, 0) / samples.length;
  }
  if (statistic === "maximum") return Math.max(...samples);
  if (statistic === "rate") {
    if (!samples.every((value) => value === 0 || value === 1)) {
      throw new Error("rate samples must be binary zero/one events");
    }
    return (samples.reduce((sum, value) => sum + value, 0) / samples.length) * 100;
  }
  if (statistic === "growth") {
    if (samples[0] === 0) throw new Error("growth samples require a positive first value");
    return ((samples.at(-1) - samples[0]) / samples[0]) * 100;
  }
  if (statistic === "count") {
    if (!samples.every((value) => Number.isInteger(value) && value >= 0)) {
      throw new Error("count samples must be non-negative integers");
    }
    return samples.reduce((sum, value) => sum + value, 0);
  }
  throw new Error(`unsupported statistic ${statistic}`);
}

export function validatePerformanceMeasurements(measurements, options = {}) {
  const errors = [];
  const label = options.label ?? "performance measurements";
  const evidencePaths = options.evidencePaths ?? null;
  const byId = new Map();
  for (const [index, measurement] of asArray(measurements).entries()) {
    const measurementLabel = `${label}[${index}]`;
    if (!isRecord(measurement) || typeof measurement.id !== "string") {
      errors.push(`${measurementLabel}.id is required`);
      continue;
    }
    if (byId.has(measurement.id)) {
      errors.push(`${label} contains duplicate measurement ${measurement.id}`);
      continue;
    }
    byId.set(measurement.id, measurement);
  }

  for (const budget of PERFORMANCE_BUDGET_CATALOG.measurements) {
    const measurement = byId.get(budget.id);
    const measurementLabel = `${label}.${budget.id}`;
    if (!measurement) {
      errors.push(`${measurementLabel} is missing`);
      continue;
    }
    for (const field of ["assertionId", "unit", "statistic", "direction", "limit", "minimumSamples", "minimumDurationSeconds"]) {
      if (measurement[field] !== budget[field]) {
        errors.push(`${measurementLabel}.${field} does not match the active release budget`);
      }
    }
    if (!finiteNumber(measurement.value)) {
      errors.push(`${measurementLabel}.value must be a finite number`);
    } else if (!passesBudget(measurement.value, budget)) {
      errors.push(
        `${measurementLabel}.value ${measurement.value} violates ${budget.direction} ${budget.limit} ${budget.unit}`,
      );
    }
    const samples = asArray(measurement.samples);
    if (samples.length > PERFORMANCE_BUDGET_CATALOG.maximumSamplesPerMeasurement) {
      errors.push(
        `${measurementLabel}.samples exceeds ${PERFORMANCE_BUDGET_CATALOG.maximumSamplesPerMeasurement}`,
      );
    }
    if (samples.length !== measurement.sampleCount) {
      errors.push(`${measurementLabel}.sampleCount must equal samples.length`);
    }
    try {
      if (samples.length > PERFORMANCE_BUDGET_CATALOG.maximumSamplesPerMeasurement) {
        throw new Error("sample series exceeds the active validation limit");
      }
      const derivedValue = derivePerformanceValue(samples, budget.statistic);
      if (
        finiteNumber(measurement.value) &&
        Math.abs(derivedValue - measurement.value) > Math.max(1e-9, Math.abs(derivedValue) * 1e-9)
      ) {
        errors.push(
          `${measurementLabel}.value ${measurement.value} does not match the independently derived value ${derivedValue}`,
        );
      }
    } catch (error) {
      errors.push(`${measurementLabel}.samples are invalid: ${error.message}`);
    }
    if (!Number.isInteger(measurement.sampleCount) || measurement.sampleCount < budget.minimumSamples) {
      errors.push(`${measurementLabel}.sampleCount must be at least ${budget.minimumSamples}`);
    }
    if (
      !finiteNumber(measurement.durationSeconds) ||
      measurement.durationSeconds < budget.minimumDurationSeconds
    ) {
      errors.push(
        `${measurementLabel}.durationSeconds must be at least ${budget.minimumDurationSeconds}`,
      );
    }
    if (typeof measurement.context !== "string" || measurement.context.trim().length === 0) {
      errors.push(`${measurementLabel}.context is required`);
    }
    const evidence = asArray(measurement.evidence);
    if (evidence.length === 0) {
      errors.push(`${measurementLabel}.evidence must reference at least one hashed file`);
    }
    if (evidencePaths) {
      for (const path of evidence) {
        if (typeof path !== "string" || !evidencePaths.has(path)) {
          errors.push(`${measurementLabel}.evidence reference is not present in receipt.evidence.files`);
        }
      }
    }
  }
  for (const id of byId.keys()) {
    if (!PERFORMANCE_BUDGET_CATALOG.measurements.some((budget) => budget.id === id)) {
      errors.push(`${label} contains unknown measurement ${id}`);
    }
  }
  return [...new Set(errors)];
}

const catalogErrors = validatePerformanceBudgetCatalog();
if (catalogErrors.length > 0) {
  throw new Error(`Invalid Windows release performance budgets:\n${catalogErrors.join("\n")}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === "--template") {
    process.stdout.write(`${JSON.stringify(performanceMeasurementTemplate(), null, 2)}\n`);
  } else {
    process.stderr.write("usage: node release-performance-budget.mjs --template\n");
    process.exitCode = 2;
  }
}
