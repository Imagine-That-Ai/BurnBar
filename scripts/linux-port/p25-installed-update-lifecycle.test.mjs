import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runP25InstalledUpdateLifecycle } from "./run-p25-installed-update-lifecycle.mjs";

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p25-lifecycle-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "run-"));
  const rawOutputDir = path.join(root, "raw");
  fs.mkdirSync(rawOutputDir, { mode: 0o700 });
  const file = (name) => {
    const value = path.join(root, name);
    fs.writeFileSync(value, name);
    return value;
  };
  return {
    root,
    options: {
      rawOutputDir,
      previousPackage: file("previous.deb"),
      previousManifest: file("previous-manifest.json"),
      previousManifestSignature: file("previous-manifest.sig"),
      previousProductClosure: file("previous-closure.json"),
      previousProductClosureSignature: file("previous-closure.sig"),
      previousReleaseTag: "linux-v1.2.2",
      previousVersion: "1.2.2",
      candidatePackage: file("candidate.deb"),
      candidateManifest: file("candidate-manifest.json"),
      candidateManifestSignature: file("candidate-manifest.sig"),
      candidateProductClosure: file("candidate-closure.json"),
      candidateProductClosureSignature: file("candidate-closure.sig"),
      releasePublicKey: file("release.pem"),
      packageChannel: "deb",
      architecture: "aarch64",
      environmentId: "ubuntu-24.04-gnome-x11-aarch64",
      targetHead: "1".repeat(40),
      candidateRunId: "252525",
      candidateArtifactDigest: `sha256:${"2".repeat(64)}`,
      packageVersion: "1.2.3",
      manifestSha256: "3".repeat(64),
      manifestSignatureSha256: "4".repeat(64),
      compositor: "Mutter",
    },
  };
}
function dependencies(options, failPhase = null) {
  let installed = "1.2.3";
  const captures = [];
  const commands = [];
  const provenance = (version) => ({
    version,
    package: {
      file: `${version}.deb`,
      sha256: version === "1.2.3" ? "a".repeat(64) : "b".repeat(64),
      size: 100,
    },
    manifest: {
      file: `${version}.json`,
      sha256: version === "1.2.3" ? options.manifestSha256 : "c".repeat(64),
      size: 100,
    },
    manifestSignature: {
      file: `${version}.sig`,
      sha256:
        version === "1.2.3" ? options.manifestSignatureSha256 : "d".repeat(64),
      size: 64,
    },
    releaseCommit: version === "1.2.3" ? options.targetHead : "0".repeat(40),
    metadata: { name: "open-burn-bar", version, architecture: "arm64" },
  });
  return {
    authenticate: (
      _options,
      _pkg,
      _manifest,
      _sig,
      _closure,
      _closureSig,
      version,
    ) => provenance(version),
    run(command, args) {
      commands.push([command, ...args]);
      if (command === "sudo") {
        const file = args.at(-1);
        installed = file.includes("previous") ? "1.2.2" : "1.2.3";
        return {
          command: [command, ...args],
          exitCode: 0,
          stdout: "",
          stderr: "",
        };
      }
      if (command === "dpkg-query")
        return {
          command: [command, ...args],
          exitCode: 0,
          stdout: installed,
          stderr: "",
        };
      throw new Error(`unexpected command ${command}`);
    },
    async capture(phaseOptions) {
      captures.push({
        phase: phaseOptions.phase,
        proxy: process.env.HTTPS_PROXY ?? null,
        packageSha256: phaseOptions.installedPackageSha256,
        releaseCommit: phaseOptions.authenticatedReleaseCommit,
      });
      if (phaseOptions.phase === failPhase)
        throw new Error(`forced ${failPhase}`);
    },
    installedAttestation() {
      return {
        manifestSha256:
          installed === "1.2.3" ? options.manifestSha256 : "c".repeat(64),
        manifestSignatureSha256:
          installed === "1.2.3"
            ? options.manifestSignatureSha256
            : "d".repeat(64),
      };
    },
    captures,
    commands,
    installed: () => installed,
  };
}

test("P-25 lifecycle uses native package commands, process-local outage, rollback, and candidate restore", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  const original = {
    HTTPS_PROXY: process.env.HTTPS_PROXY,
    https_proxy: process.env.https_proxy,
  };
  process.env.HTTPS_PROXY = "http://prior-upper.invalid:8080";
  process.env.https_proxy = "http://prior-lower.invalid:8081";
  try {
    const report = await runP25InstalledUpdateLifecycle(value.options, deps);
    assert.deepEqual(
      deps.captures.map((row) => row.phase),
      ["available", "current", "error", "restart"],
    );
    assert.equal(deps.captures[2].proxy, "http://127.0.0.1:9");
    assert.equal(process.env.HTTPS_PROXY, "http://prior-upper.invalid:8080");
    assert.equal(process.env.https_proxy, "http://prior-lower.invalid:8081");
    assert.equal(deps.captures[0].packageSha256, "b".repeat(64));
    assert.equal(deps.captures[1].packageSha256, "a".repeat(64));
    assert.equal(deps.captures[0].releaseCommit, "0".repeat(40));
    assert.equal(deps.captures[1].releaseCommit, value.options.targetHead);
    assert.deepEqual(
      report.commands.map((row) => row.phase),
      [
        "install-previous",
        "update-candidate",
        "rollback-previous",
        "restore-candidate",
      ],
    );
    assert.equal(report.networkOutage.systemNetworkMutated, false);
    assert.equal(report.networkOutage.exactPriorStateRestored, true);
    assert.equal(report.restoredCandidate, true);
    assert.ok(report.commands[0].command.includes("--allow-downgrades"));
    assert.ok(report.commands[2].command.includes("--allow-downgrades"));
    assert.equal(report.commands[0].installedManifestSha256, "c".repeat(64));
    assert.equal(
      report.commands[3].installedManifestSignatureSha256,
      value.options.manifestSignatureSha256,
    );
    assert.equal(deps.installed(), "1.2.3");
  } finally {
    if (original.HTTPS_PROXY === undefined) delete process.env.HTTPS_PROXY;
    else process.env.HTTPS_PROXY = original.HTTPS_PROXY;
    if (original.https_proxy === undefined) delete process.env.https_proxy;
    else process.env.https_proxy = original.https_proxy;
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-25 lifecycle restores the candidate when an intermediate capture fails", async () => {
  const value = fixture();
  const deps = dependencies(value.options, "current");
  try {
    await assert.rejects(
      runP25InstalledUpdateLifecycle(value.options, deps),
      /forced current/u,
    );
    assert.equal(deps.installed(), "1.2.3");
    assert.ok(
      deps.commands.some((row) =>
        row.some((part) => String(part).endsWith("candidate.deb")),
      ),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-25 lifecycle rejects a package-manager install with substituted installed attestation", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  let checks = 0;
  const validAttestation = deps.installedAttestation;
  deps.installedAttestation = () => {
    checks += 1;
    if (checks === 1)
      return {
        manifestSha256: "e".repeat(64),
        manifestSignatureSha256: "f".repeat(64),
      };
    return validAttestation();
  };
  try {
    await assert.rejects(
      runP25InstalledUpdateLifecycle(value.options, deps),
      /installed attestation does not match the authenticated release/u,
    );
    assert.equal(deps.installed(), "1.2.3");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
