#!/usr/bin/env node

import { execFile as execFileCallback, spawn } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import {
  access,
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { closeSync, constants as fsConstants, createReadStream, openSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";

const execFile = promisify(execFileCallback);
const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = path.dirname(scriptPath);
const repositoryRoot = path.resolve(scriptDirectory, "../..");
const configPath = path.join(scriptDirectory, "macos-idle-occlusion-gate.config.json");
const helperSourcePath = path.join(scriptDirectory, "macos-idle-occlusion-gate-helper.swift");
const supportedGateVersion = "P-PERF-3-macos-real-process-v1";
const measurementMethod = Object.freeze({
  processCPU: "two proc_pidinfo(PROC_PIDTASKINFO) cumulative CPU snapshots divided by monotonic uptime",
  windowControl: "DEBUG gate channel minimizes/restores the real dashboard and requires a cross-process WKWebView engine acknowledgement",
  workload: "idle dashboard with the existing --uitest seam and CPU-rendered boids kernel enabled",
  pairing: "batched visible-idle then fully-occluded-idle samples from one PID, paired by sample index",
  limitation: "window minimization is the deterministic fully occluded path; partial window overlap is not simulated",
});
const DEFAULT_EXEC_TIMEOUT_MS = 120_000;
const INFRA_REASON_CODES = new Set([
  "helper-timeout",
  "no-backdrop-ack",
  "launch-failed",
]);

class GateInfrastructureError extends Error {
  constructor(reasonCode, message, cause) {
    super(message, cause ? { cause } : undefined);
    this.name = "GateInfrastructureError";
    this.reasonCode = reasonCode;
  }
}

function infrastructureFailure(reasonCode, message, cause) {
  if (!INFRA_REASON_CODES.has(reasonCode)) {
    throw new Error(`unsupported P-PERF-3 infrastructure reason code: ${reasonCode}`);
  }
  return new GateInfrastructureError(reasonCode, message, cause);
}

function isTimeoutError(error) {
  return error?.code === "ETIMEDOUT"
    || error?.killed === true
    || /timed out|timeout/u.test(String(error?.message ?? error));
}

function errorDetail(error) {
  return [
    error?.message,
    error?.stderr,
    error?.stdout,
  ].filter(Boolean).join("\n");
}

function normalizeHelperFailure(error) {
  if (error?.reasonCode && INFRA_REASON_CODES.has(error.reasonCode)) return error;
  const detail = errorDetail(error);
  if (isTimeoutError(error)) {
    return infrastructureFailure("helper-timeout", `macOS gate helper timed out: ${detail}`, error);
  }
  if (/backdrop|acknowledge|no backdrop response|render-loop/u.test(detail)) {
    return infrastructureFailure("no-backdrop-ack", `backdrop readiness acknowledgement failed: ${detail}`, error);
  }
  return infrastructureFailure("launch-failed", `macOS gate helper failed: ${detail}`, error);
}

/**
 * Keep the failure contract in one place so the CLI and its
 * static/fixture tests cannot turn an infrastructure failure into a budget
 * result or a green exit.
 */
export function classifyGateFailure(error) {
  const reasonCode = INFRA_REASON_CODES.has(error?.reasonCode) ? error.reasonCode : null;
  return {
    status: reasonCode ? "infra-failed" : "failed",
    reasonCode,
    exitCode: reasonCode ? 3 : 1,
  };
}

function assertFinitePositive(value, name) {
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a finite positive number`);
  }
}

export function validateConfig(raw) {
  if (!raw || typeof raw !== "object") throw new Error("gate config must be an object");
  if (raw.schemaVersion !== 1) throw new Error("unsupported gate config schemaVersion");
  if (raw.gateVersion !== supportedGateVersion) {
    throw new Error(`unsupported gateVersion ${raw.gateVersion ?? "missing"}`);
  }

  const app = raw.app;
  const measurement = raw.measurement;
  const budgets = raw.budgets;
  const evidence = raw.evidence;
  if (!app || !measurement || !budgets || !evidence) {
    throw new Error("gate config is missing app, measurement, budgets, or evidence");
  }
  if (!app.relativeBundlePath?.startsWith(".derived-data/") || path.isAbsolute(app.relativeBundlePath)) {
    throw new Error("app.relativeBundlePath must be a repo-relative .derived-data path");
  }
  if (typeof app.expectedBundleIdentifier !== "string" || !app.expectedBundleIdentifier) {
    throw new Error("app.expectedBundleIdentifier is required");
  }
  if (app.executableName !== "OpenBurnBar") {
    throw new Error("app.executableName must identify the OpenBurnBar executable");
  }
  assertFinitePositive(app.maximumBuildAgeSeconds, "app.maximumBuildAgeSeconds");
  if (!Array.isArray(app.launchArguments) || !app.launchArguments.includes("--uitest")) {
    throw new Error("app.launchArguments must enable the existing --uitest launch seam");
  }
  const requiredLaunchArguments = ["-useKernelBackdrop", "YES", "-backdropKernel", "boids"];
  for (const argument of requiredLaunchArguments) {
    if (!app.launchArguments.includes(argument)) {
      throw new Error(`app.launchArguments must include ${argument}`);
    }
  }

  if (!Number.isInteger(measurement.matchedPairCount) || measurement.matchedPairCount < 3) {
    throw new Error("measurement.matchedPairCount must be an integer of at least 3");
  }
  assertFinitePositive(measurement.initialVisibleWarmupSeconds, "measurement.initialVisibleWarmupSeconds");
  assertFinitePositive(measurement.transitionSettleSeconds, "measurement.transitionSettleSeconds");
  assertFinitePositive(measurement.sampleDurationSeconds, "measurement.sampleDurationSeconds");
  assertFinitePositive(measurement.stateTransitionTimeoutSeconds, "measurement.stateTransitionTimeoutSeconds");
  if (measurement.robustStatistic !== "median") {
    throw new Error("measurement.robustStatistic must be median");
  }
  if (!Number.isInteger(measurement.minimumPositiveVisibleSamples)
      || measurement.minimumPositiveVisibleSamples < 1
      || measurement.minimumPositiveVisibleSamples > measurement.matchedPairCount) {
    throw new Error("measurement.minimumPositiveVisibleSamples is invalid");
  }
  assertFinitePositive(measurement.minimumVisibleMedianCpuPercent, "measurement.minimumVisibleMedianCpuPercent");
  assertFinitePositive(budgets.absoluteOccludedIdleCpuPercentCeiling,
    "budgets.absoluteOccludedIdleCpuPercentCeiling");
  assertFinitePositive(budgets.maximumOccludedToVisibleCpuRatio,
    "budgets.maximumOccludedToVisibleCpuRatio");
  if (budgets.maximumOccludedToVisibleCpuRatio >= 1) {
    throw new Error("relative CPU ceiling must require a real occlusion reduction");
  }
  if (evidence.schemaVersion !== 1
      || typeof evidence.defaultRelativeOutputPath !== "string"
      || !evidence.defaultRelativeOutputPath.startsWith(".derived-data/")) {
    throw new Error("evidence config must use schema v1 and a .derived-data output path");
  }
  return raw;
}

export function median(values) {
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error("median requires at least one sample");
  }
  if (values.some((value) => !Number.isFinite(value))) {
    throw new Error("median samples must be finite");
  }
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

export function medianAbsoluteDeviation(values) {
  const center = median(values);
  return median(values.map((value) => Math.abs(value - center)));
}

function validateSample(sample, expectedState, pairIndex) {
  if (!sample || sample.state !== expectedState || sample.workload !== "idle") {
    throw new Error(`pair ${pairIndex} is missing its ${expectedState} idle sample`);
  }
  for (const field of ["cpuPercent", "durationNanoseconds", "cpuDeltaNanoseconds"]) {
    if (!Number.isFinite(sample[field]) || sample[field] < 0) {
      throw new Error(`pair ${pairIndex} ${expectedState} sample has invalid ${field}`);
    }
  }
  if (sample.durationNanoseconds <= 0) {
    throw new Error(`pair ${pairIndex} ${expectedState} sample has zero duration`);
  }
  if (sample.pid <= 0 || sample.source !== "proc_pidinfo/PROC_PIDTASKINFO") {
    throw new Error(`pair ${pairIndex} ${expectedState} sample lacks real-process provenance`);
  }
}

export function summarizeAndEvaluatePairs(pairs, config) {
  validateConfig(config);
  if (!Array.isArray(pairs) || pairs.length === 0) {
    throw new Error("measurement produced zero matched samples");
  }
  if (pairs.length !== config.measurement.matchedPairCount) {
    throw new Error(
      `measurement produced ${pairs.length} pairs; expected ${config.measurement.matchedPairCount}`
    );
  }

  const visible = [];
  const occluded = [];
  for (let index = 0; index < pairs.length; index += 1) {
    const pair = pairs[index];
    if (pair.pairIndex !== index + 1) throw new Error(`pair ${index + 1} has a mismatched index`);
    validateSample(pair.visibleIdle, "visible-idle", index + 1);
    validateSample(pair.occludedIdle, "occluded-idle", index + 1);
    if (pair.visibleIdle.pid !== pair.occludedIdle.pid) {
      throw new Error(`pair ${index + 1} was not sampled from one process`);
    }
    visible.push(pair.visibleIdle.cpuPercent);
    occluded.push(pair.occludedIdle.cpuPercent);
  }

  const positiveVisibleCount = visible.filter((value) => value > 0).length;
  if (positiveVisibleCount < config.measurement.minimumPositiveVisibleSamples) {
    throw new Error(
      `only ${positiveVisibleCount} visible samples had non-zero CPU; measurement is not trustworthy`
    );
  }

  const visibleMedian = median(visible);
  const occludedMedian = median(occluded);
  if (visibleMedian < config.measurement.minimumVisibleMedianCpuPercent) {
    throw new Error(
      `visible median ${visibleMedian.toFixed(4)}% is below measurement floor `
      + `${config.measurement.minimumVisibleMedianCpuPercent}%`
    );
  }
  const ratio = occludedMedian / visibleMedian;
  const absoluteCeiling = config.budgets.absoluteOccludedIdleCpuPercentCeiling;
  const absolutePass = occludedMedian <= absoluteCeiling;
  // A ratio is only a stable signal when the visible workload itself exceeds
  // the accepted occluded-idle ceiling. Below that point, both states are in
  // the idle noise band; the absolute budget plus the deterministic rAF pause
  // tripwire remain authoritative.
  const relativeApplicable = visibleMedian >= absoluteCeiling;
  const relativeObservedPass = ratio <= config.budgets.maximumOccludedToVisibleCpuRatio;
  const relativePass = relativeApplicable ? relativeObservedPass : null;

  return {
    statistic: config.measurement.robustStatistic,
    visibleIdleCpuPercent: {
      samples: visible,
      median: visibleMedian,
      medianAbsoluteDeviation: medianAbsoluteDeviation(visible),
      positiveSampleCount: positiveVisibleCount,
    },
    occludedIdleCpuPercent: {
      samples: occluded,
      median: occludedMedian,
      medianAbsoluteDeviation: medianAbsoluteDeviation(occluded),
    },
    occludedToVisibleRatio: ratio,
    budgets: {
      absoluteOccludedIdleCpuPercentCeiling: absoluteCeiling,
      maximumOccludedToVisibleCpuRatio:
        config.budgets.maximumOccludedToVisibleCpuRatio,
    },
    checks: {
      absoluteOccludedIdleCpu: { applicable: true, pass: absolutePass },
      visibleToOccludedReduction: {
        applicable: relativeApplicable,
        pass: relativePass,
        minimumVisibleCpuPercent: absoluteCeiling,
        reason: relativeApplicable
          ? null
          : "visible median is within the accepted occluded-idle noise band",
      },
    },
    pass: absolutePass && (!relativeApplicable || relativeObservedPass),
  };
}

export function parseArguments(argumentsToParse, defaultOutputPath) {
  let outputPath = defaultOutputPath;
  const usageError = (message) => Object.assign(new Error(message), { usage: true });
  for (let index = 0; index < argumentsToParse.length; index += 1) {
    const argument = argumentsToParse[index];
    if (argument === "--output") {
      if (index + 1 >= argumentsToParse.length) {
        throw usageError("--output requires a path");
      }
      outputPath = path.resolve(argumentsToParse[index + 1]);
      index += 1;
      continue;
    }
    throw usageError(
      `unsupported argument ${argument}; the gate does not accept sample, result, app, or budget inputs`
    );
  }
  return { outputPath };
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function sha256(filePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
}

async function run(command, argumentsToRun, options = {}) {
  const { timeout: requestedTimeout, ...otherOptions } = options;
  const timeout = Number.isFinite(requestedTimeout) && requestedTimeout > 0
    ? requestedTimeout
    : DEFAULT_EXEC_TIMEOUT_MS;
  const result = await execFile(command, argumentsToRun, {
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    timeout,
    killSignal: "SIGTERM",
    ...otherOptions,
  });
  return { stdout: result.stdout.trim(), stderr: result.stderr.trim() };
}

async function runOptional(command, argumentsToRun) {
  try {
    return await run(command, argumentsToRun);
  } catch (error) {
    return { stdout: "", stderr: String(error.message ?? error), unavailable: true };
  }
}

async function compileHelper(directory) {
  const helperBinaryPath = path.join(directory, "macos-idle-occlusion-gate-helper");
  try {
    await run("/usr/bin/xcrun", [
      "swiftc",
      helperSourcePath,
      "-o",
      helperBinaryPath,
      "-framework",
      "AppKit",
      "-framework",
      "CoreGraphics",
    ]);
  } catch (error) {
    throw infrastructureFailure(
      isTimeoutError(error) ? "helper-timeout" : "launch-failed",
      `unable to compile the macOS gate helper: ${errorDetail(error)}`,
      error,
    );
  }
  await access(helperBinaryPath, fsConstants.X_OK);
  return helperBinaryPath;
}

async function helper(helperBinaryPath, command, pid, timeoutSeconds) {
  const argumentsToRun = [command, String(pid)];
  if (timeoutSeconds !== undefined) argumentsToRun.push(String(Math.ceil(timeoutSeconds * 1000)));
  let stdout;
  try {
    ({ stdout } = await run(helperBinaryPath, argumentsToRun, {
      timeout: timeoutSeconds === undefined
        ? DEFAULT_EXEC_TIMEOUT_MS
        : Math.max(1_000, Math.ceil(timeoutSeconds * 1_000)),
    }));
  } catch (error) {
    throw normalizeHelperFailure(error);
  }
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch (error) {
    throw infrastructureFailure(
      "launch-failed",
      `macOS gate helper returned invalid JSON: ${errorDetail(error)}`,
      error,
    );
  }
  if (parsed.pid !== pid) {
    throw infrastructureFailure(
      "launch-failed",
      `helper returned pid ${parsed.pid}; expected ${pid}`,
    );
  }
  return parsed;
}

async function plistValue(infoPlistPath, key) {
  const { stdout } = await run("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, infoPlistPath]);
  return stdout;
}

async function collectMachineIdentity() {
  const [productVersion, osBuild, hardwareModel, cpuBrand, logicalCPU, memoryBytes,
    architecture, kernelRelease, xcodeVersion, swiftVersion] = await Promise.all([
    run("/usr/bin/sw_vers", ["-productVersion"]),
    run("/usr/bin/sw_vers", ["-buildVersion"]),
    run("/usr/sbin/sysctl", ["-n", "hw.model"]),
    run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
    run("/usr/sbin/sysctl", ["-n", "hw.logicalcpu"]),
    run("/usr/sbin/sysctl", ["-n", "hw.memsize"]),
    run("/usr/bin/uname", ["-m"]),
    run("/usr/bin/uname", ["-r"]),
    run("/usr/bin/xcodebuild", ["-version"]),
    run("/usr/bin/xcrun", ["swiftc", "--version"]),
  ]);
  return {
    hardware: {
      model: hardwareModel.stdout,
      architecture: architecture.stdout,
      cpuBrand: cpuBrand.stdout,
      logicalCPUCount: Number(logicalCPU.stdout),
      memoryBytes: Number(memoryBytes.stdout),
    },
    os: {
      productVersion: productVersion.stdout,
      buildVersion: osBuild.stdout,
      kernelRelease: kernelRelease.stdout,
    },
    toolchain: {
      xcodeVersion: xcodeVersion.stdout.split("\n"),
      swiftVersion: swiftVersion.stdout.split("\n"),
    },
    ci: {
      githubActions: process.env.GITHUB_ACTIONS === "true",
      runnerName: process.env.RUNNER_NAME ?? null,
      runnerOS: process.env.RUNNER_OS ?? null,
      runnerArchitecture: process.env.RUNNER_ARCH ?? null,
      githubRunID: process.env.GITHUB_RUN_ID ?? null,
      githubSHA: process.env.GITHUB_SHA ?? null,
    },
  };
}

async function collectBuildIdentity(config) {
  const configuredBundlePath = path.resolve(repositoryRoot, config.app.relativeBundlePath);
  const derivedDataRoot = path.resolve(repositoryRoot, ".derived-data");
  const canonicalBundlePath = await realpath(configuredBundlePath);
  if (canonicalBundlePath !== derivedDataRoot
      && !canonicalBundlePath.startsWith(`${derivedDataRoot}${path.sep}`)) {
    throw new Error(`built app resolves outside .derived-data: ${canonicalBundlePath}`);
  }
  const executablePath = path.join(
    canonicalBundlePath,
    "Contents",
    "MacOS",
    config.app.executableName
  );
  await access(executablePath, fsConstants.X_OK);
  const canonicalExecutablePath = await realpath(executablePath);
  const infoPlistPath = path.join(canonicalBundlePath, "Contents", "Info.plist");
  const [bundleIdentifier, shortVersion, buildVersion, executableStat, signature] = await Promise.all([
    plistValue(infoPlistPath, "CFBundleIdentifier"),
    plistValue(infoPlistPath, "CFBundleShortVersionString"),
    plistValue(infoPlistPath, "CFBundleVersion"),
    stat(canonicalExecutablePath),
    runOptional("/usr/bin/codesign", ["-dv", "--verbose=4", canonicalBundlePath]),
  ]);
  if (bundleIdentifier !== config.app.expectedBundleIdentifier) {
    throw new Error(
      `built app bundle id ${bundleIdentifier} does not match ${config.app.expectedBundleIdentifier}`
    );
  }
  const ageSeconds = Math.max(0, (Date.now() - executableStat.mtimeMs) / 1000);
  if (executableStat.mtimeMs > Date.now() + 60_000) {
    throw new Error("built app executable modification time is in the future");
  }
  if (ageSeconds > config.app.maximumBuildAgeSeconds) {
    throw new Error(
      `built app is ${ageSeconds.toFixed(1)}s old; maximum is ${config.app.maximumBuildAgeSeconds}s`
    );
  }

  const signatureText = [signature.stdout, signature.stderr].filter(Boolean).join("\n");
  const signatureFields = {};
  for (const key of ["Identifier", "TeamIdentifier", "CDHash", "Signature"]) {
    const match = signatureText.match(new RegExp(`^${key}=(.+)$`, "m"));
    signatureFields[key] = match?.[1] ?? null;
  }

  return {
    bundlePath: canonicalBundlePath,
    executablePath: canonicalExecutablePath,
    expectedDerivedDataPath: config.app.relativeBundlePath,
    bundleIdentifier,
    shortVersion,
    buildVersion,
    executableSHA256: await sha256(canonicalExecutablePath),
    executableSizeBytes: executableStat.size,
    executableModifiedAt: executableStat.mtime.toISOString(),
    executableAgeSecondsAtGateStart: ageSeconds,
    codeSignature: signatureFields,
  };
}

async function commandLineForPID(pid, timeoutSeconds) {
  try {
    const { stdout } = await run(
      "/bin/ps",
      ["-ww", "-p", String(pid), "-o", "command="],
      timeoutSeconds === undefined ? {} : { timeout: timeoutSeconds * 1_000 },
    );
    return stdout;
  } catch (error) {
    throw normalizeHelperFailure(error);
  }
}

async function findConflictingGateProcess(helperBinaryPath, buildIdentity, config) {
  let stdout;
  try {
    ({ stdout } = await run("/usr/bin/pgrep", ["-x", config.app.executableName]));
  } catch (error) {
    if (error.code === 1) return null;
    throw error;
  }
  const candidates = stdout.split(/\s+/).map(Number).filter((pid) => Number.isInteger(pid) && pid > 0);
  for (const pid of candidates) {
    try {
      const timeout = config.measurement.stateTransitionTimeoutSeconds;
      const current = await helper(helperBinaryPath, "status", pid, timeout);
      const commandLine = await commandLineForPID(pid, timeout);
      const hasGateArguments = config.app.launchArguments.every((argument) => commandLine.includes(argument));
      if (current.executablePath === buildIdentity.executablePath
          && current.bundleIdentifier === config.app.expectedBundleIdentifier
          && hasGateArguments) {
        return { pid, commandLine, initialState: current };
      }
    } catch (error) {
      // Any failed identity inspection is untrustworthy. Do not turn an
      // uninspectable candidate into a fresh-run claim.
      if (error instanceof GateInfrastructureError) throw error;
      throw infrastructureFailure(
        "launch-failed",
        `unable to inspect existing OpenBurnBar pid ${pid}: ${errorDetail(error)}`,
        error,
      );
    }
  }
  return null;
}

async function waitForRegisteredProcess(helperBinaryPath, pid, timeoutSeconds) {
  const deadline = process.hrtime.bigint() + BigInt(Math.ceil(timeoutSeconds * 1_000_000_000));
  let lastError;
  while (process.hrtime.bigint() < deadline) {
    try {
      return await helper(helperBinaryPath, "status", pid, timeoutSeconds);
    } catch (error) {
      if (error?.reasonCode === "helper-timeout") throw error;
      lastError = error;
      await sleep(100);
    }
  }
  throw infrastructureFailure(
    "launch-failed",
    `OpenBurnBar pid ${pid} did not register with AppKit: ${lastError?.message ?? "timeout"}`,
    lastError,
  );
}

function waitForChildSpawn(child, timeoutSeconds) {
  const timeoutMilliseconds = Math.max(1_000, Math.ceil(timeoutSeconds * 1_000));
  return new Promise((resolve, reject) => {
    let timer;
    const cleanup = () => {
      clearTimeout(timer);
      child.removeListener("spawn", onSpawn);
      child.removeListener("error", onError);
    };
    const onSpawn = () => {
      cleanup();
      resolve();
    };
    const onError = (error) => {
      cleanup();
      reject(infrastructureFailure(
        "launch-failed",
        `OpenBurnBar process failed to launch: ${errorDetail(error)}`,
        error,
      ));
    };
    timer = setTimeout(() => {
      cleanup();
      reject(infrastructureFailure(
        "launch-failed",
        `OpenBurnBar process did not spawn within ${timeoutMilliseconds}ms`,
      ));
    }, timeoutMilliseconds);
    child.once("spawn", onSpawn);
    child.once("error", onError);
  });
}

export async function launchFreshProcess(
  helperBinaryPath,
  buildIdentity,
  config,
  workDirectory,
  operations = {}
) {
  const findConflict = operations.findConflictingGateProcess ?? findConflictingGateProcess;
  const spawnProcess = operations.spawn ?? spawn;
  const waitForProcess = operations.waitForRegisteredProcess ?? waitForRegisteredProcess;
  const readCommandLine = operations.commandLineForPID ?? commandLineForPID;
  const stopProcess = operations.stopOwnedProcess ?? stopOwnedProcess;
  const conflicting = await findConflict(helperBinaryPath, buildIdentity, config);
  if (conflicting) {
    throw new Error(
      `performance gate requires a fresh process; refusing to reuse existing pid ${conflicting.pid}`
    );
  }

  // `CFFIXED_USER_HOME` must point at a path Core Foundation has not already
  // initialized. Pointing it at mkdtemp's existing directory makes macOS 27
  // reuse the real preference domain and prevents the WebKit data store from
  // mounting in the isolated launch. Keep the control directory private until
  // this point, then make it traversable and let the app create `home` itself.
  await chmod(workDirectory, 0o755);
  const isolatedHomeDirectory = path.join(workDirectory, "home");
  const logPath = path.join(workDirectory, "app-process.log");
  const logHandle = openSync(logPath, "a", 0o600);
  let logHandleClosed = false;
  const closeLogHandle = () => {
    if (logHandleClosed) return;
    logHandleClosed = true;
    closeSync(logHandle);
  };
  let child;
  try {
    child = spawnProcess(buildIdentity.executablePath, config.app.launchArguments, {
      cwd: repositoryRoot,
      env: {
        ...process.env,
        CFFIXED_USER_HOME: isolatedHomeDirectory,
        HOME: isolatedHomeDirectory,
        OPENBURNBAR_UITEST: "1",
        // Random per-run SQLCipher key so the encrypted store opens without a
        // Keychain prompt, without relying on any predictable constant.
        OPENBURNBAR_UITEST_DB_KEY: randomBytes(32).toString("base64"),
        OPENBURNBAR_FORCE_LIVE_SCENE: "1",
        OPENBURNBAR_E2E_HOLD_OPEN: "1",
        OPENBURNBAR_PERFORMANCE_GATE: "1",
        NSUnbufferedIO: "YES",
      },
      stdio: ["ignore", logHandle, logHandle],
    });
    child.once("spawn", closeLogHandle);
    child.once("error", closeLogHandle);
    await waitForChildSpawn(child, config.measurement.stateTransitionTimeoutSeconds);
    const pid = child.pid;
    const initialState = await waitForProcess(
      helperBinaryPath,
      pid,
      config.measurement.stateTransitionTimeoutSeconds
    );
    const commandLine = await readCommandLine(pid);
    return {
      pid,
      commandLine,
      initialState,
      mode: "launched",
      child,
    };
  } catch (launchError) {
    closeLogHandle();
    if (Number.isInteger(child?.pid) && child.pid > 0) {
      try {
        await stopProcess({ pid: child.pid, mode: "launched", child });
      } catch (cleanupError) {
        throw new AggregateError(
          [launchError, cleanupError],
          `fresh process launch failed and pid ${child.pid} cleanup also failed`
        );
      }
    }
    throw launchError;
  }
}

async function stopOwnedProcess(runtime) {
  if (!runtime?.child || runtime.child.exitCode !== null) return;
  runtime.child.kill("SIGTERM");
  const exited = once(runtime.child, "exit");
  const timedOut = sleep(5_000).then(() => "timeout");
  if (await Promise.race([exited.then(() => "exit"), timedOut]) === "timeout") {
    runtime.child.kill("SIGKILL");
    await once(runtime.child, "exit").catch(() => {});
  }
}

export function assertProcessIdentity(state, pid, buildIdentity, config, expectedVisibility) {
  if (!state.running || state.pid !== pid) throw new Error(`OpenBurnBar pid ${pid} is not running`);
  if (state.executablePath !== buildIdentity.executablePath) {
    throw new Error(`pid ${pid} executable changed to ${state.executablePath ?? "missing"}`);
  }
  if (state.bundleIdentifier !== config.app.expectedBundleIdentifier) {
    throw new Error(`pid ${pid} bundle identifier changed to ${state.bundleIdentifier ?? "missing"}`);
  }
  if (expectedVisibility === "visible" && (state.hidden || state.visibleWindowCount < 1)) {
    throw new Error(`pid ${pid} did not have a visible dashboard window`);
  }
  if (expectedVisibility === "occluded" && state.visibleWindowCount !== 0) {
    throw new Error(`pid ${pid} still had an on-screen application window`);
  }
  const kernelArgumentIndex = config.app.launchArguments.indexOf("-backdropKernel");
  const expectedKernel = config.app.launchArguments[kernelArgumentIndex + 1];
  if (state.backdropReady !== true) {
    throw infrastructureFailure(
      "no-backdrop-ack",
      `pid ${pid} did not acknowledge a ready backdrop engine`,
    );
  }
  if (state.backdropKernel !== expectedKernel) {
    throw infrastructureFailure(
      "no-backdrop-ack",
      `pid ${pid} acknowledged kernel ${state.backdropKernel ?? "missing"}; expected ${expectedKernel}`
    );
  }
  const expectedActive = expectedVisibility === "visible";
  if (state.backdropActive !== expectedActive) {
    throw infrastructureFailure(
      "no-backdrop-ack",
      `pid ${pid} backdrop active state did not match ${expectedVisibility}`,
    );
  }
  if (state.backdropReducedMotion !== false) {
    throw infrastructureFailure(
      "no-backdrop-ack",
      `pid ${pid} backdrop cannot prove animation while reduced motion is active`,
    );
  }
  if (state.backdropRenderLoopScheduled !== expectedActive) {
    throw infrastructureFailure(
      "no-backdrop-ack",
      `pid ${pid} backdrop render-loop state did not match ${expectedVisibility}`,
    );
  }
}

async function takeCPUSample(
  helperBinaryPath,
  pid,
  state,
  durationSeconds,
  helperTimeoutSeconds = DEFAULT_EXEC_TIMEOUT_MS / 1_000,
) {
  const first = await helper(helperBinaryPath, "cpu", pid, helperTimeoutSeconds);
  await sleep(durationSeconds * 1000);
  const second = await helper(helperBinaryPath, "cpu", pid, helperTimeoutSeconds);
  const durationNanoseconds = Number(BigInt(second.monotonicNanoseconds) - BigInt(first.monotonicNanoseconds));
  const cpuDeltaNanoseconds = Number(BigInt(second.cpuNanoseconds) - BigInt(first.cpuNanoseconds));
  if (!Number.isSafeInteger(durationNanoseconds) || durationNanoseconds <= 0) {
    throw new Error(`${state} sample has invalid monotonic duration`);
  }
  if (!Number.isSafeInteger(cpuDeltaNanoseconds) || cpuDeltaNanoseconds < 0) {
    throw new Error(`${state} sample has invalid process CPU delta`);
  }
  const cpuPercent = (cpuDeltaNanoseconds / durationNanoseconds) * 100;
  return {
    state,
    workload: "idle",
    pid,
    source: "proc_pidinfo/PROC_PIDTASKINFO",
    monotonicClock: "DispatchTime.uptimeNanoseconds",
    startedMonotonicNanoseconds: first.monotonicNanoseconds,
    endedMonotonicNanoseconds: second.monotonicNanoseconds,
    startedProcessCpuNanoseconds: first.cpuNanoseconds,
    endedProcessCpuNanoseconds: second.cpuNanoseconds,
    durationNanoseconds,
    cpuDeltaNanoseconds,
    cpuPercent,
  };
}

export async function measureMatchedPairs(
  helperBinaryPath,
  runtime,
  buildIdentity,
  config,
  partialMeasurement,
  operations = {}
) {
  const runHelper = operations.helper ?? helper;
  const sampleCPU = operations.takeCPUSample ?? takeCPUSample;
  const wait = operations.sleep ?? sleep;
  const monotonicNow = operations.monotonicNow
    ?? (() => process.hrtime.bigint().toString());
  const pid = runtime.pid;
  const timeout = config.measurement.stateTransitionTimeoutSeconds;
  const initialVisible = await runHelper(helperBinaryPath, "show", pid, timeout);
  assertProcessIdentity(initialVisible, pid, buildIdentity, config, "visible");
  await wait(config.measurement.initialVisibleWarmupSeconds * 1000);

  const { pairs, transitions } = partialMeasurement;
  transitions.push({
    state: "initial-visible",
    atMonotonicNanoseconds: monotonicNow(),
    observed: initialVisible,
  });

  const visibleSamples = [];
  for (let pairIndex = 1; pairIndex <= config.measurement.matchedPairCount; pairIndex += 1) {
    const visibleState = await runHelper(helperBinaryPath, "wait-visible", pid, timeout);
    assertProcessIdentity(visibleState, pid, buildIdentity, config, "visible");
    visibleSamples.push(await sampleCPU(
      helperBinaryPath,
      pid,
      "visible-idle",
      config.measurement.sampleDurationSeconds,
      timeout
    ));
  }

  const hiddenState = await runHelper(helperBinaryPath, "hide", pid, timeout);
  assertProcessIdentity(hiddenState, pid, buildIdentity, config, "occluded");
  transitions.push({
    state: "occluded",
    afterVisibleSampleCount: visibleSamples.length,
    atMonotonicNanoseconds: monotonicNow(),
    observed: hiddenState,
  });
  await wait(config.measurement.transitionSettleSeconds * 1000);

  for (let pairIndex = 1; pairIndex <= config.measurement.matchedPairCount; pairIndex += 1) {
    if (pairIndex > 1) {
      const stillHidden = await runHelper(helperBinaryPath, "wait-hidden", pid, timeout);
      assertProcessIdentity(stillHidden, pid, buildIdentity, config, "occluded");
    }
    const occludedIdle = await sampleCPU(
      helperBinaryPath,
      pid,
      "occluded-idle",
      config.measurement.sampleDurationSeconds,
      timeout
    );
    pairs.push({
      pairIndex,
      visibleIdle: visibleSamples[pairIndex - 1],
      occludedIdle,
    });
  }
  return partialMeasurement;
}

async function writeEvidence(outputPath, evidence) {
  await mkdir(path.dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
  await rename(temporaryPath, outputPath);
}

async function executeGate(argumentsToParse) {
  if (process.platform !== "darwin") {
    throw infrastructureFailure(
      "launch-failed",
      "P-PERF-3 real-process CPU gate requires macOS",
    );
  }
  const rawConfig = JSON.parse(await readFile(configPath, "utf8"));
  const config = validateConfig(rawConfig);
  const defaultOutputPath = path.resolve(repositoryRoot, config.evidence.defaultRelativeOutputPath);
  const { outputPath } = parseArguments(argumentsToParse, defaultOutputPath);
  await mkdir(path.dirname(outputPath), { recursive: true });
  await unlink(outputPath).catch((error) => {
    if (error.code !== "ENOENT") throw error;
  });

  const runID = randomUUID();
  const startedAt = new Date();
  const startedMonotonicNanoseconds = process.hrtime.bigint();
  const workDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-macos-cpu-gate-"));
  let runtime;
  let machineIdentity;
  let buildIdentity;
  let configSHA256;
  let helperSourceSHA256;
  let evidence;
  let measurement;
  let summary;

  try {
    [machineIdentity, buildIdentity, configSHA256, helperSourceSHA256] = await Promise.all([
      collectMachineIdentity(),
      collectBuildIdentity(config),
      sha256(configPath),
      sha256(helperSourcePath),
    ]);
    const helperBinaryPath = await compileHelper(workDirectory);
    runtime = await launchFreshProcess(helperBinaryPath, buildIdentity, config, workDirectory);
    measurement = { pairs: [], transitions: [] };
    measurement = await measureMatchedPairs(
      helperBinaryPath,
      runtime,
      buildIdentity,
      config,
      measurement
    );
    summary = summarizeAndEvaluatePairs(measurement.pairs, config);
    const finishedMonotonicNanoseconds = process.hrtime.bigint();
    evidence = {
      schemaVersion: config.evidence.schemaVersion,
      gateVersion: config.gateVersion,
      runID,
      status: summary.pass ? "passed" : "failed",
      failureClass: summary.pass ? null : "budget",
      reasonCode: null,
      startedAt: startedAt.toISOString(),
      finishedAt: new Date().toISOString(),
      startedMonotonicNanoseconds: startedMonotonicNanoseconds.toString(),
      finishedMonotonicNanoseconds: finishedMonotonicNanoseconds.toString(),
      durationNanoseconds: (finishedMonotonicNanoseconds - startedMonotonicNanoseconds).toString(),
      evidenceFreshness: {
        existingOutputRemovedBeforeMeasurement: true,
        acceptsSeededSamplesOrResults: false,
        configSHA256,
        helperSourceSHA256,
      },
      measurementMethod,
      machineIdentity,
      buildIdentity,
      processIdentity: {
        pid: runtime.pid,
        mode: runtime.mode,
        executablePath: buildIdentity.executablePath,
        bundleIdentifier: buildIdentity.bundleIdentifier,
        commandLine: runtime.commandLine,
        realProcessVerified: true,
      },
      config,
      transitions: measurement.transitions,
      matchedPairs: measurement.pairs,
      summary,
    };
    await writeEvidence(outputPath, evidence);

    if (!summary.pass) {
      const failures = Object.entries(summary.checks)
        .filter(([, check]) => check.pass === false)
        .map(([name]) => name)
        .join(", ");
      throw Object.assign(new Error(`P-PERF-3 CPU budget breached: ${failures}`), {
        evidenceAlreadyWritten: true,
      });
    }

    const relativeCheck = summary.checks.visibleToOccludedReduction;
    const relativeResult = relativeCheck.applicable
      ? `ratio ${summary.occludedToVisibleRatio.toFixed(3)} `
        + `(ceiling ${summary.budgets.maximumOccludedToVisibleCpuRatio})`
      : `ratio not applicable (visible median `
        + `${summary.visibleIdleCpuPercent.median.toFixed(3)}% is below `
        + `${relativeCheck.minimumVisibleCpuPercent}% signal floor)`;
    process.stdout.write(
      `P-PERF-3 passed: occluded median ${summary.occludedIdleCpuPercent.median.toFixed(3)}% `
      + `(ceiling ${summary.budgets.absoluteOccludedIdleCpuPercentCeiling}%), `
      + `${relativeResult}; evidence ${outputPath}\n`
    );
    return { outputPath, evidence };
  } catch (error) {
    if (!error.evidenceAlreadyWritten) {
      const evidenceError = error.reasonCode
        ? error
        : infrastructureFailure(
          "launch-failed",
          `P-PERF-3 setup or measurement infrastructure failed: ${errorDetail(error)}`,
          error,
        );
      const failedAtMonotonicNanoseconds = process.hrtime.bigint();
      const classification = classifyGateFailure(evidenceError);
      evidence = {
        schemaVersion: 1,
        gateVersion: rawConfig?.gateVersion ?? "unknown",
        runID,
        status: classification.status,
        failureClass: classification.reasonCode ? "infra" : "unknown",
        reasonCode: classification.reasonCode,
        startedAt: startedAt.toISOString(),
        finishedAt: new Date().toISOString(),
        startedMonotonicNanoseconds: startedMonotonicNanoseconds.toString(),
        finishedMonotonicNanoseconds: failedAtMonotonicNanoseconds.toString(),
        durationNanoseconds: (failedAtMonotonicNanoseconds - startedMonotonicNanoseconds).toString(),
        evidenceFreshness: {
          existingOutputRemovedBeforeMeasurement: true,
          acceptsSeededSamplesOrResults: false,
          configSHA256: configSHA256 ?? null,
          helperSourceSHA256: helperSourceSHA256 ?? null,
        },
        machineIdentity: machineIdentity ?? null,
        buildIdentity: buildIdentity ?? null,
        processIdentity: runtime ? {
          pid: runtime.pid,
          mode: runtime.mode,
          executablePath: buildIdentity?.executablePath ?? null,
          realProcessVerified: false,
        } : null,
        measurementMethod,
        transitions: measurement?.transitions ?? null,
        matchedPairs: measurement?.pairs ?? null,
        error: String(evidenceError.stack ?? evidenceError.message ?? evidenceError),
      };
      await writeEvidence(outputPath, evidence);
      error = evidenceError;
    }
    throw error;
  } finally {
    await stopOwnedProcess(runtime);
    await rm(workDirectory, { recursive: true, force: true });
  }
}

export async function main(argumentsToParse = process.argv.slice(2)) {
  try {
    await executeGate(argumentsToParse);
  } catch (error) {
    const classifiedError = error?.reasonCode || error?.evidenceAlreadyWritten || error?.usage
      ? error
      : infrastructureFailure(
        "launch-failed",
        `P-PERF-3 could not start or complete its evidence run: ${errorDetail(error)}`,
        error,
      );
    process.stderr.write(`error: ${classifiedError.message ?? classifiedError}\n`);
    process.exitCode = classifyGateFailure(classifiedError).exitCode;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
