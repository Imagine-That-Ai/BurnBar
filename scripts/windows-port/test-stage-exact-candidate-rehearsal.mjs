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
// Destructive staging must fail closed: unsafe/protected roots are refused and
// a non-empty RepoRoot requires an explicit disposable opt-in.
assert.match(script, /function Assert-SafeRehearsalRoot/);
assert.match(script, /Refusing filesystem-root rehearsal RepoRoot/);
assert.match(script, /Refusing suspiciously short rehearsal RepoRoot/);
assert.match(script, /Refusing protected rehearsal RepoRoot/);
assert.match(script, /Refusing rehearsal RepoRoot that contains this running checkout/);
assert.match(script, /RepoRoot already exists and is not empty/);
assert.match(script, /\[switch\] \$ForceReplaceRepoRoot/);
assert.ok(
  script.indexOf("Assert-SafeRehearsalRoot $RepoRoot") <
    script.indexOf("Remove-DirectoryWithRetry $RepoRoot"),
  "safety guard must run before the staging directory is deleted",
);
// The artifact manifest must carry and match the expected source commit.
assert.match(script, /'sourceCommit',/);
assert.match(script, /Artifact manifest source commit mismatch/);
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
