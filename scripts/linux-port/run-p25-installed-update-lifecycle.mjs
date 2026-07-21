#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { captureP25NativeUpdatePhase } from "./run-p25-native-update-probes.mjs";

const SHA256 = /^[a-f0-9]{64}$/u;
const RELEASE_COMMIT = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/u;
const FORMATS = Object.freeze({
  deb: {
    manager: "apt",
    packageName: "open-burn-bar",
    architecture: { aarch64: "arm64", x86_64: "amd64" },
  },
  rpm: {
    manager: "dnf",
    packageName: "open-burn-bar",
    architecture: { aarch64: "aarch64", x86_64: "x86_64" },
  },
  arch: {
    manager: "pacman",
    packageName: "openburnbar",
    architecture: { aarch64: "aarch64", x86_64: "x86_64" },
  },
});

function assert(value, message) {
  if (!value) throw new Error(message);
}
function bytes(file) {
  const stat = fs.lstatSync(file);
  assert(
    stat.isFile() && !stat.isSymbolicLink(),
    `P-25 requires a regular file: ${file}`,
  );
  return fs.readFileSync(file);
}
function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}
function artifactRecord(file) {
  const value = bytes(file);
  return {
    file: path.basename(file),
    sha256: sha256(value),
    size: value.length,
  };
}
function readJson(file, label) {
  try {
    return JSON.parse(bytes(file).toString("utf8"));
  } catch (error) {
    throw new Error(`${label} is invalid JSON: ${error.message}`);
  }
}
function verifySignature(file, signatureFile, publicKeyFile, label) {
  const value = bytes(file);
  const signature = bytes(signatureFile);
  const key = crypto.createPublicKey(bytes(publicKeyFile));
  assert(
    key.asymmetricKeyType === "ed25519" &&
      signature.length === 64 &&
      crypto.verify(null, value, key, signature),
    `${label} signature is invalid`,
  );
  return {
    document: readJson(file, label),
    record: artifactRecord(file),
    signature: artifactRecord(signatureFile),
  };
}
function defaultRun(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    timeout: 180_000,
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  return {
    command: [command, ...args],
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}
function runRequired(run, command, args, label, options) {
  const result = run(command, args, options);
  assert(
    result.exitCode === 0,
    `${label} failed: ${result.stderr || result.stdout}`,
  );
  return result;
}
function packageMetadata(run, format, file) {
  if (format === "deb")
    return {
      name: runRequired(
        run,
        "dpkg-deb",
        ["-f", file, "Package"],
        "Debian package name",
      ).stdout.trim(),
      version: runRequired(
        run,
        "dpkg-deb",
        ["-f", file, "Version"],
        "Debian package version",
      ).stdout.trim(),
      architecture: runRequired(
        run,
        "dpkg-deb",
        ["-f", file, "Architecture"],
        "Debian package architecture",
      ).stdout.trim(),
    };
  if (format === "rpm")
    return {
      name: runRequired(
        run,
        "rpm",
        ["-qp", "--qf", "%{NAME}", file],
        "RPM package name",
      ).stdout.trim(),
      version: runRequired(
        run,
        "rpm",
        ["-qp", "--qf", "%{VERSION}", file],
        "RPM package version",
      ).stdout.trim(),
      architecture: runRequired(
        run,
        "rpm",
        ["-qp", "--qf", "%{ARCH}", file],
        "RPM package architecture",
      ).stdout.trim(),
    };
  const info = runRequired(
    run,
    "bsdtar",
    ["-xOf", file, ".PKGINFO"],
    "Arch package metadata",
  ).stdout;
  const fields = Object.fromEntries(
    info
      .split("\n")
      .map((line) => line.split(" = "))
      .filter((row) => row.length === 2),
  );
  return {
    name: fields.pkgname,
    version: String(fields.pkgver ?? "").replace(/-[1-9][0-9]*$/u, ""),
    architecture: fields.arch,
  };
}
function installedVersion(run, format) {
  if (format === "deb")
    return runRequired(
      run,
      "dpkg-query",
      ["-W", "-f=${Version}", "open-burn-bar"],
      "installed Debian version",
    ).stdout.trim();
  if (format === "rpm")
    return runRequired(
      run,
      "rpm",
      ["-q", "--qf", "%{VERSION}", "open-burn-bar"],
      "installed RPM version",
    ).stdout.trim();
  return (
    runRequired(run, "pacman", ["-Q", "openburnbar"], "installed Arch version")
      .stdout.trim()
      .split(/\s+/u)[1] ?? ""
  ).replace(/-[1-9][0-9]*$/u, "");
}
function installCommand(format, file, rollback = false) {
  if (format === "deb")
    return [
      "sudo",
      [
        "apt-get",
        "install",
        "-y",
        "--reinstall",
        ...(rollback ? ["--allow-downgrades"] : []),
        file,
      ],
    ];
  if (format === "rpm")
    return ["sudo", ["dnf", rollback ? "downgrade" : "install", "-y", file]];
  return ["sudo", ["pacman", "-U", "--noconfirm", file]];
}
function authenticateRelease(
  options,
  packageFile,
  manifestFile,
  signatureFile,
  closureFile,
  closureSignatureFile,
  version,
  label,
) {
  const manifest = verifySignature(
    manifestFile,
    signatureFile,
    options.releasePublicKey,
    `${label} manifest`,
  );
  const closure = verifySignature(
    closureFile,
    closureSignatureFile,
    options.releasePublicKey,
    `${label} product closure`,
  );
  const packageRecord = artifactRecord(packageFile);
  const metadata = packageMetadata(
    options.run,
    options.packageChannel,
    packageFile,
  );
  const expected = FORMATS[options.packageChannel];
  assert(
    metadata.name === expected.packageName &&
      metadata.version === version &&
      metadata.architecture === expected.architecture[options.architecture],
    `${label} package identity is invalid`,
  );
  assert(
    manifest.document.packageName === expected.packageName &&
      manifest.document.packageFormat === options.packageChannel &&
      manifest.document.packageArchitecture === options.architecture &&
      manifest.document.packageVersion === version &&
      RELEASE_COMMIT.test(manifest.document.gitCommit),
    `${label} installed manifest identity is invalid`,
  );
  assert(
    closure.document.status === "passed" &&
      closure.document.version === version,
    `${label} product closure is not passed`,
  );
  assert(
    closure.document.targetHead === manifest.document.gitCommit,
    `${label} product closure commit does not match its signed installed manifest`,
  );
  const rows = (closure.document.packages ?? []).filter(
    (row) =>
      row.format === options.packageChannel &&
      row.architecture === options.architecture,
  );
  assert(
    rows.length === 1,
    `${label} product closure has no exact package row`,
  );
  const row = rows[0];
  assert(
    row.artifact?.sha256 === packageRecord.sha256 &&
      row.artifact?.size === packageRecord.size &&
      row.installedManifest?.sha256 === manifest.record.sha256 &&
      row.installedManifestSignature?.sha256 === manifest.signature.sha256,
    `${label} public package provenance does not match signed closure`,
  );
  return {
    version,
    package: packageRecord,
    manifest: manifest.record,
    manifestSignature: manifest.signature,
    releaseCommit: manifest.document.gitCommit,
    metadata,
  };
}
function proxySnapshot() {
  return {
    HTTPS_PROXY: process.env.HTTPS_PROXY ?? null,
    https_proxy: process.env.https_proxy ?? null,
  };
}
function restoreProxy(snapshot) {
  for (const key of ["HTTPS_PROXY", "https_proxy"])
    if (snapshot[key] === null) delete process.env[key];
    else process.env[key] = snapshot[key];
}
function sameProxy(left, right) {
  return (
    left.HTTPS_PROXY === right.HTTPS_PROXY &&
    left.https_proxy === right.https_proxy
  );
}
function phaseProvenance(release) {
  return {
    installedPackageSha256: release.package.sha256,
    installedManifestSha256: release.manifest.sha256,
    installedManifestSignatureSha256: release.manifestSignature.sha256,
    authenticatedReleaseCommit: release.releaseCommit,
  };
}

export async function runP25InstalledUpdateLifecycle(
  options,
  dependencies = {},
) {
  const format = options.packageChannel;
  assert(FORMATS[format], "P-25 requires deb, rpm, or arch package ownership");
  assert(
    ["aarch64", "x86_64"].includes(options.architecture),
    "P-25 architecture is invalid",
  );
  assert(
    RELEASE_COMMIT.test(options.targetHead),
    "P-25 target HEAD is invalid",
  );
  assert(
    /^sha256:[a-f0-9]{64}$/u.test(options.candidateArtifactDigest),
    "P-25 candidate artifact digest is invalid",
  );
  assert(
    String(options.candidateRunId).length > 0,
    "P-25 candidate run ID is required",
  );
  assert(options.environmentId, "P-25 environment ID is required");
  const run = dependencies.run ?? defaultRun;
  const auth = dependencies.authenticate ?? authenticateRelease;
  const authenticationOptions = { ...options, run };
  const previous = auth(
    authenticationOptions,
    options.previousPackage,
    options.previousManifest,
    options.previousManifestSignature,
    options.previousProductClosure,
    options.previousProductClosureSignature,
    options.previousVersion,
    "previous",
  );
  const candidate = auth(
    authenticationOptions,
    options.candidatePackage,
    options.candidateManifest,
    options.candidateManifestSignature,
    options.candidateProductClosure,
    options.candidateProductClosureSignature,
    options.packageVersion,
    "candidate",
  );
  assert(
    candidate.releaseCommit === options.targetHead,
    "P-25 candidate provenance does not match target HEAD",
  );
  assert(
    candidate.manifest.sha256 === options.manifestSha256 &&
      candidate.manifestSignature.sha256 === options.manifestSignatureSha256,
    "P-25 candidate installed attestation does not match the invoked release closure",
  );
  assert(
    previous.version !== candidate.version,
    "P-25 previous and candidate releases must differ",
  );
  const dataRoot = path.join(
    process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local/share"),
    "openburnbar",
  );
  fs.mkdirSync(dataRoot, { recursive: true });
  const sentinel = path.join(
    dataRoot,
    `.p25-update-${options.candidateRunId}.sentinel`,
  );
  fs.writeFileSync(
    sentinel,
    `p25:${options.candidateRunId}:${options.targetHead}\n`,
    {
      mode: 0o600,
      flag: "wx",
    },
  );
  const sentinelSha256 = sha256(bytes(sentinel));
  const commands = [];
  const preservation = {};
  const priorProxy = proxySnapshot();
  const capture = dependencies.capture ?? captureP25NativeUpdatePhase;
  const installedAttestation =
    dependencies.installedAttestation ??
    (() => ({
      manifestSha256: artifactRecord(
        "/usr/share/openburnbar/attestation/installed-manifest.json",
      ).sha256,
      manifestSignatureSha256: artifactRecord(
        "/usr/share/openburnbar/attestation/installed-manifest.json.sig",
      ).sha256,
    }));
  let restored = false;
  const install = (phase, file, release, rollback = false) => {
    const [command, args] = installCommand(format, file, rollback);
    const result = runRequired(run, command, args, `P-25 ${phase}`);
    const version = installedVersion(run, format);
    assert(
      version === release.version,
      `P-25 ${phase} installed ${version}, expected ${release.version}`,
    );
    const installed = installedAttestation();
    assert(
      installed.manifestSha256 === release.manifest.sha256 &&
        installed.manifestSignatureSha256 === release.manifestSignature.sha256,
      `P-25 ${phase} installed attestation does not match the authenticated release`,
    );
    const currentSentinel = sha256(bytes(sentinel));
    assert(
      currentSentinel === sentinelSha256,
      `P-25 ${phase} changed persisted data`,
    );
    commands.push({
      phase,
      command: result.command,
      exitCode: result.exitCode,
      installedVersion: version,
      packageSha256: release.package.sha256,
      installedManifestSha256: installed.manifestSha256,
      installedManifestSignatureSha256: installed.manifestSignatureSha256,
    });
    preservation[phase] = currentSentinel;
  };
  try {
    install("install-previous", options.previousPackage, previous, true);
    await capture({
      ...options,
      ...phaseProvenance(previous),
      phase: "available",
      expectedVersion: options.previousVersion,
    });
    install("update-candidate", options.candidatePackage, candidate);
    await capture({
      ...options,
      ...phaseProvenance(candidate),
      phase: "current",
      expectedVersion: options.packageVersion,
    });
    try {
      process.env.HTTPS_PROXY = "http://127.0.0.1:9";
      process.env.https_proxy = "http://127.0.0.1:9";
      await capture(
        {
          ...options,
          ...phaseProvenance(candidate),
          phase: "error",
          expectedVersion: options.packageVersion,
        },
        dependencies.captureDependencies,
      );
    } finally {
      restoreProxy(priorProxy);
    }
    assert(
      sameProxy(proxySnapshot(), priorProxy),
      "P-25 did not restore the exact prior proxy environment",
    );
    install("rollback-previous", options.previousPackage, previous, true);
    install("restore-candidate", options.candidatePackage, candidate);
    await capture({
      ...options,
      ...phaseProvenance(candidate),
      phase: "restart",
      expectedVersion: options.packageVersion,
    });
    restored = true;
    const restorationReceipt = commands.at(-1);
    const report = {
      schemaVersion: 1,
      producer: "openburnbar-p25-native-package-lifecycle-v1",
      targetHead: options.targetHead,
      candidateRunId: String(options.candidateRunId),
      candidateArtifactDigest: options.candidateArtifactDigest,
      environmentId: options.environmentId,
      architecture: options.architecture,
      packageChannel: format,
      manager: FORMATS[format].manager,
      packageName: FORMATS[format].packageName,
      candidate,
      previous: { ...previous, releaseTag: options.previousReleaseTag },
      commands,
      networkOutage: {
        method: "process-local-invalid-https-proxy",
        endpoint: "127.0.0.1:9",
        priorEnvironment: priorProxy,
        restoredEnvironment: proxySnapshot(),
        systemNetworkMutated: false,
        exactPriorStateRestored: sameProxy(proxySnapshot(), priorProxy),
      },
      lifecycle: {
        update: {
          status: "passed",
          fromVersion: options.previousVersion,
          toVersion: options.packageVersion,
        },
        rollback: {
          status: "passed",
          fromVersion: options.packageVersion,
          toVersion: options.previousVersion,
        },
        dataPreservation: {
          status: "passed",
          sentinelSha256,
          afterPreviousSha256: preservation["install-previous"],
          afterUpdateSha256: preservation["update-candidate"],
          afterRollbackSha256: preservation["rollback-previous"],
          afterRestoreSha256: preservation["restore-candidate"],
        },
      },
      restoration: {
        status: "passed",
        installedVersion: restorationReceipt.installedVersion,
        candidatePackageSha256: restorationReceipt.packageSha256,
        installedManifestSha256: restorationReceipt.installedManifestSha256,
        installedManifestSignatureSha256:
          restorationReceipt.installedManifestSignatureSha256,
      },
      restoredCandidate: true,
      passed: true,
    };
    fs.writeFileSync(
      path.join(options.rawOutputDir, "updates-package-lifecycle.json"),
      `${JSON.stringify(report, null, 2)}\n`,
      { mode: 0o600, flag: "wx" },
    );
    return report;
  } finally {
    restoreProxy(priorProxy);
    if (!restored) {
      try {
        install(
          "emergency-restore-candidate",
          options.candidatePackage,
          candidate,
        );
      } catch (error) {
        process.stderr.write(
          `P-25 CRITICAL candidate restoration failed: ${error.message}\n`,
        );
        throw error;
      }
    }
    fs.rmSync(sentinel, { force: true });
  }
}

function parse(argv) {
  const flags = [
    "raw-output-dir",
    "previous-package",
    "previous-manifest",
    "previous-manifest-signature",
    "previous-product-closure",
    "previous-product-closure-signature",
    "previous-release-tag",
    "previous-version",
    "candidate-package",
    "candidate-manifest",
    "candidate-manifest-signature",
    "candidate-product-closure",
    "candidate-product-closure-signature",
    "release-public-key",
    "package-channel",
    "architecture",
    "environment",
    "target-head",
    "candidate-run-id",
    "candidate-artifact-digest",
    "package-version",
    "manifest-sha256",
    "manifest-signature-sha256",
    "compositor",
  ];
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index]?.replace(/^--/u, "");
    if (!flags.includes(name) || values[name] || argv[index + 1] === undefined)
      throw new Error(`invalid argument ${argv[index]}`);
    values[name] = argv[index + 1];
  }
  for (const flag of flags)
    if (!values[flag]) throw new Error(`--${flag} is required`);
  return Object.fromEntries(
    Object.entries(values).map(([key, value]) => [
      key.replace(/-([a-z])/gu, (_, letter) => letter.toUpperCase()),
      value,
    ]),
  );
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    process.stdout.write(
      `${JSON.stringify(await runP25InstalledUpdateLifecycle(parse(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-25 installed update lifecycle failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
