import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const script = readFileSync(join(root, "stage-exact-candidate-rehearsal.ps1"), "utf8");

assert.match(script, /ExpectedCommit must be a full 40-character Git SHA/);
assert.match(script, /Artifact SHA-256 mismatch/);
assert.match(script, /Get-AuthenticodeSignature/);
assert.match(script, /Authenticode signer mismatch/);
assert.match(script, /Exact source commit mismatch/);
assert.match(script, /reset --mixed HEAD/);
assert.match(script, /Unable to rebuild the exact-candidate Git index/);
assert.match(script, /config core\.fileMode false/);
assert.match(script, /Unable to configure Windows Git file-mode semantics/);
assert.match(script, /config core\.longpaths true/);
assert.match(script, /Unable to configure Windows Git long-path semantics/);
assert.match(script, /Staged exact-candidate source tree is dirty/);
assert.match(script, /Remove-DirectoryWithRetry/);
assert.match(script, /Unable to clear rehearsal directory after \$attempt attempts/);
assert.match(script, /function Expand-ZipWithTar/);
assert.match(script, /System32\\tar\.exe/);
assert.doesNotMatch(script, /Expand-Archive/);
assert.match(script, /run-physical-release-certification\.ps1/);
assert.match(script, /\$RunnerScriptPath = \(Join-Path \$PSScriptRoot/);
assert.match(script, /\$runner = Resolve-ExistingFile \$RunnerScriptPath/);
assert.doesNotMatch(script, /\$runner = Join-Path \$RepoRoot/);
assert.match(script, /certificationRunnerSha256 = Get-Sha256 \$runner/);
assert.match(script, /physicalCertificationClaimed = \$false/);
assert.doesNotMatch(script, /PhysicalHardware\s*=\s*\$true/);

console.log("PASS: exact-candidate rehearsal staging structural checks");
