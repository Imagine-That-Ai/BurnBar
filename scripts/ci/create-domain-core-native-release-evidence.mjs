#!/usr/bin/env node

import {
  appendFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { run as createReleaseEvidence } from "./create-domain-core-release-evidence.mjs";
import {
  inactiveCandidateIdentity,
  nativeAttestationName,
  nativeEvidenceDomains,
  nativePredicateName,
  publicProfileSha256,
  validateNativeActivationSelector,
  validateResolvedProfile,
} from "../lib/domain-core-native-release.mjs";
import {
  DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
  RELEASE_CONSUMERS,
  expectedArtifactName,
  validateCandidateBundle,
} from "../lib/domain-core-release-evidence.mjs";

const STABLE_VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const APPLE_ANDROID_VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const FULL_SHA = /^[0-9a-f]{40}$/u;

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function regularFile(path, label) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error(`${label} must be a nonempty regular file`);
  }
  return path;
}

function writeCreateOnly(path, value) {
  const contents = `${JSON.stringify(value, null, 2)}\n`;
  mkdirSync(dirname(path), { recursive: true });
  try {
    writeFileSync(path, contents, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    regularFile(path, "immutable native evidence plan");
    if (readFileSync(path, "utf8") !== contents) {
      throw new Error(
        `refusing to replace non-identical native evidence plan: ${path}`,
      );
    }
  }
}

function positiveInteger(value, label) {
  if (!/^[1-9]\d*$/u.test(value)) {
    throw new Error(`${label} must be a positive integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new Error(`${label} is too large`);
  return parsed;
}

function parseArguments(argv) {
  const required = new Set([
    "--consumer",
    "--artifact",
    "--version",
    "--tag",
    "--commit",
    "--profile-name",
    "--profile",
    "--activation",
    "--output-dir",
  ]);
  // Only a Rust activation has an attested candidate bundle, a promotion
  // attestation, a rollback artifact, and a protected signer run to bind
  // evidence to. run() demands each of these once it knows the activation is
  // active; a legacy release has none of them to pass.
  const optional = new Set([
    "--github-output",
    "--android-abi-manifest",
    "--candidate-bundle",
    "--promotion-attestation",
    "--protected-signer-run-id",
    "--protected-signer-run-attempt",
    "--rollback-artifact",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag) && !optional.has(flag)) {
      throw new Error(`unknown argument: ${String(flag)}`);
    }
    if (!value || value.startsWith("--")) {
      throw new Error(`${flag} requires a value`);
    }
    if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of required) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

function requiredArgument(args, flag) {
  const value = args.get(flag);
  if (!value) throw new Error(`${flag} is required`);
  return value;
}

export function run(argv, { promotionVerifier, activationVerifier } = {}) {
  const args = parseArguments(argv);
  const consumer = args.get("--consumer");
  const contract = RELEASE_CONSUMERS[consumer];
  if (!contract || !new Set(["apple", "android", "windows"]).has(consumer)) {
    throw new Error(`unsupported native release consumer: ${String(consumer)}`);
  }
  const version = args.get("--version");
  const versionPattern = new Set(["apple", "android"]).has(consumer)
    ? APPLE_ANDROID_VERSION
    : STABLE_VERSION;
  if (!versionPattern.test(version))
    throw new Error("native release version is invalid");
  const tag = args.get("--tag");
  const expectedTag =
    consumer === "windows" ? `windows-v${version}` : `v${version}`;
  if (tag !== expectedTag)
    throw new Error(`native release tag must be ${expectedTag}`);
  const commit = args.get("--commit");
  if (!FULL_SHA.test(commit))
    throw new Error("native release commit is invalid");
  const artifact = regularFile(
    resolve(args.get("--artifact")),
    "native release artifact",
  );
  if (artifact.split("/").at(-1) !== expectedArtifactName(consumer, version)) {
    throw new Error(
      `native artifact must be named ${expectedArtifactName(consumer, version)}`,
    );
  }
  const activationDocument = readJson(
    resolve(args.get("--activation")),
    "release activation",
  );
  const rustActive = activationDocument?.active !== false;
  const candidateBundle = rustActive
    ? resolve(requiredArgument(args, "--candidate-bundle"))
    : undefined;
  const candidate = candidateBundle
    ? validateCandidateBundle(readJson(candidateBundle, "candidate bundle"))
        .candidate
    : inactiveCandidateIdentity(activationDocument);
  const profileName = args.get("--profile-name");
  const profile = validateResolvedProfile(
    readJson(resolve(args.get("--profile")), "selected public profile"),
    profileName,
    candidate,
  );
  const profileSha256 = publicProfileSha256(profile, profileName, candidate);
  const activationSelector = validateNativeActivationSelector(
    activationDocument,
    { candidate, releaseCommit: commit, profile, profileName },
  );
  const signerRunId = rustActive
    ? positiveInteger(
        requiredArgument(args, "--protected-signer-run-id"),
        "protected signer run ID",
      )
    : undefined;
  const signerRunAttempt = rustActive
    ? positiveInteger(
        requiredArgument(args, "--protected-signer-run-attempt"),
        "protected signer run attempt",
      )
    : undefined;
  const outputDirectory = resolve(args.get("--output-dir"));
  mkdirSync(outputDirectory, { recursive: true });
  const predicateActivationPath = join(
    outputDirectory,
    "domain-core-release-activation.json",
  );
  writeCreateOnly(predicateActivationPath, activationSelector.activation);
  const domains = nativeEvidenceDomains(consumer, profile, profileName);
  if (!rustActive && domains.length > 0) {
    throw new Error(
      "inactive release activation cannot ship native evidence domains",
    );
  }
  const androidAbiManifest = args.get("--android-abi-manifest");
  if (rustActive && consumer === "android" && !androidAbiManifest) {
    throw new Error("android requires --android-abi-manifest");
  }
  if (consumer !== "android" && androidAbiManifest) {
    throw new Error(`${consumer} must not provide --android-abi-manifest`);
  }
  const entries = [];
  for (const domain of domains) {
    const predicatePath = join(
      outputDirectory,
      nativePredicateName(consumer, version, domain),
    );
    const evidenceArguments = [
      "--consumer",
      consumer,
      "--domain",
      domain,
      "--artifact-kind",
      contract.artifactKind,
      "--target",
      contract.target,
      "--version",
      version,
      "--tag",
      tag,
      "--commit",
      commit,
      "--artifact",
      artifact,
      "--predicate",
      predicatePath,
      "--public-profile-sha256",
      activationSelector.domains.get(domain).publicProfileSha256,
      "--activation",
      predicateActivationPath,
      "--candidate-bundle",
      candidateBundle,
      "--promotion-attestation",
      resolve(requiredArgument(args, "--promotion-attestation")),
      "--protected-signer-run-id",
      String(signerRunId),
      "--protected-signer-run-attempt",
      String(signerRunAttempt),
      "--rollback-artifact",
      resolve(requiredArgument(args, "--rollback-artifact")),
    ];
    if (androidAbiManifest) {
      evidenceArguments.push(
        "--android-abi-manifest",
        resolve(androidAbiManifest),
      );
    }
    createReleaseEvidence(evidenceArguments, {
      promotionVerifier,
      activationVerifier,
    });
    entries.push({
      domain,
      publicProfileSha256:
        activationSelector.domains.get(domain).publicProfileSha256,
      predicatePath,
      predicateType: DOMAIN_CORE_RELEASE_PREDICATE_TYPE,
      bundleAssetName: nativeAttestationName(consumer, version, domain),
    });
  }
  const plan = {
    schemaVersion: 2,
    consumer,
    version,
    tag,
    commit,
    profileName,
    publicProfileSha256: profileSha256,
    activation: activationSelector.activation,
    artifactPath: artifact,
    signerWorkflow: contract.signerWorkflow,
    rollback: profileName === "public-production-rollback",
    ...(androidAbiManifest
      ? { androidAbiManifestPath: resolve(androidAbiManifest) }
      : {}),
    domains: entries,
  };
  const planPath = join(
    outputDirectory,
    "domain-core-native-evidence-plan.json",
  );
  writeCreateOnly(planPath, plan);
  const githubOutput = args.get("--github-output");
  if (githubOutput) {
    const flags = Object.fromEntries(
      contract.domains.map((domain) => [
        `domain_${domain.replace(/[A-Z]/gu, (value) => `_${value.toLowerCase()}`)}`,
        domains.includes(domain) ? "true" : "false",
      ]),
    );
    appendFileSync(
      githubOutput,
      Object.entries({
        plan_path: planPath,
        evidence_count: domains.length,
        ...flags,
      })
        .map(([key, value]) => `${key}=${value}`)
        .join("\n") + "\n",
      "utf8",
    );
  }
  process.stdout.write(`${JSON.stringify({ ok: true, planPath, ...plan })}\n`);
  return plan;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
