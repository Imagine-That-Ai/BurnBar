#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { candidateCloseRefusal } from './lib/candidate-fingerprint.mjs';
import {
  isMainModule,
  isObject,
  looksLikePlaceholder,
  readJson,
  walkFiles
} from './lib/check-support.mjs';
import { resolveConfinedPath } from './lib/path-confine.mjs';
import { repoRoot } from './lib/repo-root.mjs';
import { buildCandidateReceipt } from './record-candidate-fingerprint.mjs';

export const EVIDENCE_DIR = 'docs/mobile-parity/evidence';
export const STORE_READBACK_PATH = 'docs/mobile-parity/store-readback.json';
export const LEDGER_PATH = 'docs/mobile-parity/mobile-parity-ledger.json';

export const IOS_SOURCE_GRAPH_COMMANDS = [
  'node scripts/privacy/scan-chat-cloud-plaintext.mjs',
  'swift test --package-path OpenBurnBarCore --filter FirestorePlaintextProhibitionTests',
  './scripts/test-openburnbar-mobile.sh --only-testing OpenBurnBarMobileTests/FirestorePlaintextProhibitionTests'
];

export const SIGNAL_ARTIFACT_COMMANDS = [
  'test -d Vendor/OpenBurnBarSignalFfiIOS.xcframework -o -d Vendor/OpenBurnBarSignalFfi.xcframework',
  'OPENBURNBAR_MOBILE_SKIP_SIGNAL_FFI_PREP=1 ./scripts/test-openburnbar-mobile.sh --dry-run'
];

export const ANDROID_ABI_COMMANDS = [
  './scripts/ci/verify-android-16kb-page-size.sh',
  'node scripts/ci/verify-domain-core-android-universal-artifact.mjs'
];

const STORE_FIELDS = ['version', 'build', 'artifactDigest', 'track', 'reviewState', 'testerAvailability'];

function storeComplete(platform) {
  if (!isObject(platform)) return false;
  if (platform.status === 'blocked') return false;
  return STORE_FIELDS.every((field) => {
    const value = platform[field];
    return typeof value === 'string' && value.trim().length > 0;
  });
}

function fingerprintHasArtifactDigest(receipt) {
  const artifacts = Array.isArray(receipt?.nativeArtifacts) ? receipt.nativeArtifacts : [];
  return artifacts.some((item) => (
    item &&
    item.present === true &&
    typeof item.sha256 === 'string' &&
    item.sha256.trim().length > 0
  ));
}

export function storeValidatedAllowed(store, receipt) {
  const appleOk = storeComplete(store?.apple);
  const googleOk = storeComplete(store?.google);
  const fingerprintClean = receipt?.dirty !== true && (receipt?.dirtyEntries?.length ?? 0) === 0;
  return appleOk && googleOk && fingerprintClean && fingerprintHasArtifactDigest(receipt);
}

export function inspectEvidenceBundle(root, relative = EVIDENCE_DIR) {
  const failures = [];
  const resolved = resolveConfinedPath(root, relative);
  if (resolved.error || !resolved.exists) {
    return { failures: [`missing evidence directory: ${relative}`], files: [] };
  }
  const files = walkFiles(resolved.path);
  for (const file of files) {
    const rel = path.relative(root, file).split(path.sep).join('/');
    const stat = fs.statSync(file);
    const base = path.basename(file);
    if (base === 'README.md' || base === 'bundle-status.json') continue;
    if (stat.size === 0) {
      failures.push(`empty evidence file rejected: ${rel}`);
      continue;
    }
    const text = fs.readFileSync(file, 'utf8');
    if (looksLikePlaceholder(text)) {
      failures.push(`placeholder evidence rejected: ${rel}`);
    }
    if (/\bPASS\b/u.test(text) && !rel.endsWith('candidate-fingerprint.json')) {
      failures.push(`placeholder PASS evidence rejected: ${rel}`);
    }
  }
  return { failures, files: files.map((file) => path.relative(root, file).split(path.sep).join('/')) };
}

export function runAndroidAbiPageSize(root, options = {}) {
  const runner = options.runner ?? ((command, args, spawnOptions) => spawnSync(command, args, spawnOptions));
  const apkPath = options.apkPath ?? path.join(root, 'android/app/build/outputs/apk/debug/app-debug.apk');
  const script = path.join(root, 'scripts/ci/verify-android-16kb-page-size.sh');
  const command = ANDROID_ABI_COMMANDS[0];
  if (!fs.existsSync(script)) {
    return { status: 'blocked', exitCode: null, command, detail: 'verifier script is missing' };
  }
  if (!fs.existsSync(apkPath)) {
    return {
      status: 'blocked',
      exitCode: null,
      command,
      detail: 'Android APK / native artifact is not present in this worktree'
    };
  }
  const result = runner('bash', [script, apkPath], { cwd: root, encoding: 'utf8' });
  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (result.status === 0) {
    return { status: 'ran', exitCode: 0, command, detail: output.trim() };
  }
  const missingTool = /zipalign not found|llvm-objdump not found|Android APK not found/iu.test(output);
  return {
    status: missingTool ? 'blocked' : 'failed',
    exitCode: result.status,
    command,
    detail: output.trim() || `exit ${result.status}`
  };
}

export function runAndroidAbiCoverage(root, options = {}) {
  const runner = options.runner ?? ((command, args, spawnOptions) => spawnSync(command, args, spawnOptions));
  const script = path.join(root, 'scripts/ci/verify-domain-core-android-universal-artifact.mjs');
  const command = ANDROID_ABI_COMMANDS[1];
  if (!fs.existsSync(script)) {
    return { status: 'blocked', exitCode: null, command, detail: 'verifier script is missing' };
  }
  const result = runner(process.execPath, [script], { cwd: root, encoding: 'utf8' });
  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (result.status === 0) {
    return { status: 'ran', exitCode: 0, command, detail: output.trim() };
  }
  const missingArtifact = /missing|not found|ENOENT|must be a nonempty|--aab is required|--apk is required/iu.test(output);
  return {
    status: missingArtifact ? 'blocked' : 'failed',
    exitCode: result.status,
    command,
    detail: output.trim() || `exit ${result.status}`
  };
}

export function runAndroidFirebaseStrictRelease(root, options = {}) {
  const runner = options.runner ?? ((command, args, spawnOptions) => spawnSync(command, args, spawnOptions));
  const script = path.join(root, 'scripts/ci/verify-android-firebase-release-config.mjs');
  if (!fs.existsSync(script)) {
    return {
      status: 'blocked',
      exitCode: null,
      command: 'node scripts/ci/verify-android-firebase-release-config.mjs --strict-release',
      detail: 'verifier script is missing'
    };
  }
  const result = runner(process.execPath, [script, '--strict-release'], {
    cwd: root,
    encoding: 'utf8'
  });
  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (result.status === 0) {
    return {
      status: 'ran',
      exitCode: 0,
      command: 'node scripts/ci/verify-android-firebase-release-config.mjs --strict-release',
      detail: output.trim()
    };
  }
  const missingConfig = /Unable to read|google-services\.json|Invalid Android Firebase config|project_id must be|api_key must|oauth_client must|placeholder/iu.test(output);
  return {
    status: missingConfig ? 'blocked' : 'failed',
    exitCode: result.status,
    command: 'node scripts/ci/verify-android-firebase-release-config.mjs --strict-release',
    detail: output.trim() || `exit ${result.status}`
  };
}

export function validateReleaseEvidence(options = {}) {
  const failures = [];
  const warnings = [];
  const root = options.repoRoot ?? repoRoot;
  const receipt = options.receipt ?? buildCandidateReceipt(root, {
    fingerprint: options.fingerprint
  });
  const refusal = candidateCloseRefusal({
    commitSha: receipt.commitSha,
    dirty: receipt.dirty,
    dirtyEntries: receipt.dirtyEntries
  });
  if (receipt.closable === true && refusal) {
    failures.push(`fingerprint marked closable but ${refusal}`);
  }
  if (receipt.dirty === true || (receipt.dirtyEntries?.length ?? 0) > 0) {
    if (receipt.closable === true) {
      failures.push('dirty candidate cannot close');
    } else {
      warnings.push('dirty tree: candidate is not closable');
    }
  }

  const evidence = inspectEvidenceBundle(root, options.evidenceDir ?? EVIDENCE_DIR);
  failures.push(...evidence.failures);

  const storeDoc = readJson(root, options.storeReadbackPath ?? STORE_READBACK_PATH);
  if (storeDoc.error) failures.push(storeDoc.error);
  const store = storeDoc.value;
  if (store) {
    if (store.status === 'validated' || store.status === 'PASS') {
      if (!storeValidatedAllowed(store, receipt)) {
        failures.push('store readback cannot be validated without collected fields');
      }
    }
    for (const platform of ['apple', 'google']) {
      if (!isObject(store[platform])) {
        failures.push(`store readback missing ${platform}`);
        continue;
      }
      for (const field of STORE_FIELDS) {
        if (store[platform][field] !== null && store[platform].status === 'blocked') {
          warnings.push(`${platform}.${field} is set while platform status is blocked`);
        }
      }
    }
  }

  const ledgerDoc = readJson(root, options.ledgerPath ?? LEDGER_PATH);
  if (ledgerDoc.error) failures.push(ledgerDoc.error);
  const val015 = (ledgerDoc.value?.rows ?? []).find((row) => row.id === 'VAL-MOB-015');
  if (val015?.status === 'validated' || val015?.result === 'PASS') {
    const appleOk = storeComplete(store?.apple);
    const googleOk = storeComplete(store?.google);
    if (!appleOk || !googleOk) {
      failures.push('VAL-MOB-015 cannot be validated without store readback fields');
    }
    if (refusal) failures.push(`VAL-MOB-015 cannot close: ${refusal}`);
  }

  const androidFirebase = options.androidFirebase
    ?? runAndroidFirebaseStrictRelease(root, options);
  if (androidFirebase.status === 'failed') {
    failures.push(`Android Firebase strict-release failed: ${androidFirebase.detail}`);
  } else if (androidFirebase.status === 'blocked') {
    warnings.push(`Android Firebase strict-release blocked: ${androidFirebase.detail}`);
  }

  const nativeArtifacts = receipt.nativeArtifacts;
  if (!Array.isArray(nativeArtifacts) || nativeArtifacts.length === 0) {
    failures.push('candidate fingerprint is missing native artifact digests');
  }

  const androidAbiPageSize = options.androidAbiPageSize ?? runAndroidAbiPageSize(root, options);
  const androidAbiCoverage = options.androidAbiCoverage ?? runAndroidAbiCoverage(root, options);
  for (const check of [androidAbiPageSize, androidAbiCoverage]) {
    if (check.status === 'failed') {
      failures.push(`Android ABI check failed: ${check.detail}`);
    } else if (check.status === 'blocked') {
      warnings.push(`Android ABI check blocked: ${check.detail}`);
    }
  }

  const commands = {
    androidFirebase: androidFirebase.command,
    iosSourceFirestoreGraph: IOS_SOURCE_GRAPH_COMMANDS,
    signalArtifacts: SIGNAL_ARTIFACT_COMMANDS,
    androidAbi: {
      androidAbiPageSize: androidAbiPageSize.command,
      androidAbiCoverage: androidAbiCoverage.command,
      status: androidAbiPageSize.status,
      coverageStatus: androidAbiCoverage.status,
      missingPrerequisite: androidAbiPageSize.status === 'blocked' ? androidAbiPageSize.detail : null
    }
  };

  return {
    passed: failures.length === 0,
    failures,
    warnings,
    receipt,
    androidFirebase,
    androidAbiPageSize,
    androidAbiCoverage,
    commands,
    storeStatus: store?.status ?? 'missing'
  };
}

function main() {
  const result = validateReleaseEvidence();
  console.log(JSON.stringify({
    passed: result.passed,
    productParityClaim: false,
    storeStatus: result.storeStatus,
    closable: result.receipt.closable,
    dirty: result.receipt.dirty,
    androidFirebase: {
      status: result.androidFirebase.status,
      exitCode: result.androidFirebase.exitCode
    },
    androidAbi: {
      pageSize: result.androidAbiPageSize?.status,
      coverage: result.androidAbiCoverage?.status
    },
    commands: result.commands,
    warnings: result.warnings,
    failures: result.failures
  }, null, 2));
  process.exit(result.passed ? 0 : 1);
}

if (isMainModule(import.meta.url)) main();
