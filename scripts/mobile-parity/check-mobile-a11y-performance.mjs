#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileMentions, isObject, readJson, runCheckCli, walkFiles } from './lib/check-support.mjs';
import { resolveConfinedPath } from './lib/path-confine.mjs';
import { repoRoot } from './lib/repo-root.mjs';

export const A11Y_POLICY_PATH = 'docs/mobile-parity/mobile-a11y-performance-policy.json';
export const A11Y_VECTORS_PATH = 'docs/mobile-parity/fixtures/product/a11y-contract-vectors.json';

export const A11Y_TEST_FILES = {
  swift: [
    'OpenBurnBarCore/Tests/OpenBurnBarCoreTests/MobileAccessibilityParityTests.swift'
  ],
  kotlin: [
    'android/app/src/test/java/com/openburnbar/data/policy/MobileAccessibilityParityTest.kt'
  ]
};

export const PRIMARY_SURFACES = {
  ios: [
    'OpenBurnBarMobile/Views/Pulse',
    'OpenBurnBarMobile/Views/Burn',
    'OpenBurnBarMobile/Views/Hermes/HermesTabView.swift',
    'OpenBurnBarMobile/Views/Inbox',
    'OpenBurnBarMobile/Views/Store',
    'OpenBurnBarMobile/Views/ComputerUse'
  ],
  android: [
    'android/app/src/main/java/com/openburnbar/ui/pulse',
    'android/app/src/main/java/com/openburnbar/ui/burn',
    'android/app/src/main/java/com/openburnbar/ui/hermes',
    'android/app/src/main/java/com/openburnbar/ui/inbox',
    'android/app/src/main/java/com/openburnbar/ui/store',
    'android/app/src/main/java/com/openburnbar/ui/computeruse'
  ]
};

const REQUIRED_KINDS = new Set([
  'heroBurn',
  'quotaRing',
  'stopButton',
  'inboxRow',
  'chart',
  'iconOnly',
  'loading',
  'error',
  'liveStream'
]);

export function validateMobileA11yPerformance(options = {}) {
  const failures = [];
  const root = options.repoRoot ?? repoRoot;
  const policyDoc = readJson(root, options.policyPath ?? A11Y_POLICY_PATH);
  if (policyDoc.error) return { passed: false, failures: [policyDoc.error], ids: [] };
  const vectorsDoc = readJson(root, options.vectorsPath ?? A11Y_VECTORS_PATH);
  if (vectorsDoc.error) return { passed: false, failures: [vectorsDoc.error], ids: [] };

  const policy = policyDoc.value;
  const vectors = vectorsDoc.value;
  if (policy.id !== 'openburnbar-mobile-a11y-performance-policy-v1') {
    failures.push('a11y policy id must be openburnbar-mobile-a11y-performance-policy-v1');
  }
  if (policy.productParityClaim === true) {
    failures.push('a11y policy productParityClaim must stay false');
  }
  if (policy.contrast?.minimumNormalText < 4.5) {
    failures.push('contrast floor must be at least 4.5:1 for normal text');
  }
  if (policy.touchTarget?.minimumPt < 44 || policy.touchTarget?.minimumDp < 48) {
    failures.push('touch target floor must be 44pt / 48dp');
  }
  if (policy.performance?.pulseWindowMetrics?.complexity !== 'O(n)') {
    failures.push('pulse window metrics budget must be O(n)');
  }
  if (policy.performance?.backgroundRetry?.unbounded === true) {
    failures.push('background retry must not be unbounded');
  }
  if (policy.manualEvidence?.voiceOver === 'PASS' || policy.manualEvidence?.talkBack === 'PASS') {
    failures.push('manual VoiceOver/TalkBack cannot be claimed PASS without named-device evidence');
  }

  if (vectors.id !== 'openburnbar-mobile-a11y-contract-vectors-v1') {
    failures.push('a11y vectors id mismatch');
  }
  const ids = [];
  const kinds = new Set();
  for (const vector of vectors.vectors ?? []) {
    if (!vector?.id) {
      failures.push('a11y vector is missing id');
      continue;
    }
    ids.push(vector.id);
    kinds.add(vector.kind);
    if (!isObject(vector.expected) || !vector.expected.label) {
      failures.push(`${vector.id} must pin expected.label`);
    }
  }
  for (const kind of REQUIRED_KINDS) {
    if (!kinds.has(kind)) failures.push(`a11y vectors missing required kind ${kind}`);
  }

  const unique = new Set(ids);
  if (unique.size !== ids.length) failures.push('a11y vector ids must be unique');

  const swiftFiles = options.swiftFiles ?? A11Y_TEST_FILES.swift;
  const kotlinFiles = options.kotlinFiles ?? A11Y_TEST_FILES.kotlin;
  for (const id of unique) {
    if (!swiftFiles.some((file) => fileMentions(root, file, id))) {
      failures.push(`no Swift test file references vector ${id}`);
    }
    if (!kotlinFiles.some((file) => fileMentions(root, file, id))) {
      failures.push(`no Kotlin test file references vector ${id}`);
    }
  }

  const theme = resolveConfinedPath(root, 'OpenBurnBarMobile/Theme/MobileTheme.swift');
  if (theme.exists) {
    const text = fs.readFileSync(theme.path, 'utf8');
    if (!text.includes('MobileScaledFont')) {
      failures.push('MobileTheme.Typography must use MobileScaledFont for Dynamic Type');
    }
  }

  const iosSurfaces = options.iosSurfaces ?? PRIMARY_SURFACES.ios;
  const fixedSystemFont = /\.font\(\s*\.system\(size:|Font\.system\(size:/u;
  for (const relative of iosSurfaces) {
    const resolved = resolveConfinedPath(root, relative);
    if (resolved.error || !resolved.exists) continue;
    for (const file of walkFiles(resolved.path)) {
      if (!file.endsWith('.swift')) continue;
      const text = fs.readFileSync(file, 'utf8');
      for (const line of text.split('\n')) {
        if (!fixedSystemFont.test(line)) continue;
        if (line.includes('MobileScaledFont.system')) continue;
        failures.push(`fixed Font.system(size:) is forbidden on primary surfaces: ${path.relative(root, file)}`);
        break;
      }
    }
  }

  const unlabeledPrimary = /contentDescription\s*=\s*null/u;
  const chartFiles = [
    'android/app/src/main/java/com/openburnbar/ui/pulse/PulseLiveCostCurveSections.kt',
    'android/app/src/main/java/com/openburnbar/ui/pulse/VelocityForecastCardSections.kt'
  ];
  for (const relative of chartFiles) {
    const resolved = resolveConfinedPath(root, relative);
    if (resolved.error || !resolved.exists) continue;
    const text = fs.readFileSync(resolved.path, 'utf8');
    if (unlabeledPrimary.test(text)) {
      failures.push(`unlabeled chart/icon node on primary surface: ${relative}`);
    }
  }

  const androidSurfaces = options.androidSurfaces ?? PRIMARY_SURFACES.android;
  const dpFont = /fontSize\s*=\s*[0-9.]+\s*\.dp/u;
  for (const relative of androidSurfaces) {
    const resolved = resolveConfinedPath(root, relative);
    if (resolved.error || !resolved.exists) continue;
    for (const file of walkFiles(resolved.path)) {
      if (!file.endsWith('.kt')) continue;
      const text = fs.readFileSync(file, 'utf8');
      if (dpFont.test(text)) {
        failures.push(`fixed-dp fontSize is forbidden on primary surfaces: ${path.relative(root, file)}`);
      }
    }
  }

  const pulseSwift = resolveConfinedPath(
    root,
    'OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/MobilePulseWindowPolicy.swift'
  );
  if (pulseSwift.exists) {
    const text = fs.readFileSync(pulseSwift.path, 'utf8');
    if (!text.includes('usages.filter')) {
      failures.push('Pulse window metrics must remain a single pass over usages');
    }
  }

  return { passed: failures.length === 0, failures, ids: [...unique] };
}

runCheckCli(
  import.meta.url,
  validateMobileA11yPerformance,
  (result) => `mobile a11y/performance policy ok (${result.ids.length} ids)`
);
