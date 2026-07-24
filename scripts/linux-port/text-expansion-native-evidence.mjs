import fs from 'node:fs';
import path from 'node:path';

export const TEXT_EXPANSION_NATIVE_SOURCE = 'linux-swift-tests/daemon-linux.xml';
export const TEXT_EXPANSION_NATIVE_RECEIPT = 'text-expansion-native-persistence-evidence.json';
export const TEXT_EXPANSION_NATIVE_CLASS = 'OpenBurnBarDaemonLinuxGatewayTests.BurnBarTextExpansionServiceTests';
export const TEXT_EXPANSION_NATIVE_TEST = 'testEncryptedPersistenceConsentRestartAndPermissions';

const TESTCASE_PATTERN = /<testcase\b[^>]*(?:\/>|>[\s\S]*?<\/testcase>)/gu;
const FAILURE_MARKER_PATTERN = /<(failure|error|skipped)\b[^>]*(?:\/>|>)/gu;

function targetCaseEvidence(xml) {
  const cases = [...xml.matchAll(TESTCASE_PATTERN)].map(([block]) => {
    const className = block.match(/\bclassname="([^"]+)"/u)?.[1] ?? null;
    const name = block.match(/\bname="([^"]+)"/u)?.[1] ?? null;
    const failureMarkers = [...block.matchAll(FAILURE_MARKER_PATTERN)].map(([, marker]) => marker);
    return { block, className, name, failureMarkers };
  });
  const matches = cases.filter((candidate) => (
    candidate.className === TEXT_EXPANSION_NATIVE_CLASS &&
    candidate.name === TEXT_EXPANSION_NATIVE_TEST
  ));
  const candidate = matches.length === 1 ? matches[0] : null;
  return {
    matchedTestCases: matches.length,
    passed: candidate !== null && candidate.failureMarkers.length === 0,
    test: {
      className: TEXT_EXPANSION_NATIVE_CLASS,
      name: TEXT_EXPANSION_NATIVE_TEST,
      status: candidate === null
        ? (matches.length === 0 ? 'missing' : 'ambiguous')
        : candidate.failureMarkers.length === 0 ? 'passed' : 'failed',
      failureMarkers: candidate?.failureMarkers ?? []
    }
  };
}

export function deriveTextExpansionNativeEvidence(xml, source = TEXT_EXPANSION_NATIVE_SOURCE) {
  if (typeof xml !== 'string' || xml.trim().length === 0) {
    return {
      schemaVersion: 1,
      type: 'openburnbar.linux.text-expansion-native-persistence',
      source,
      passed: false,
      matchedTestCases: 0,
      test: {
        className: TEXT_EXPANSION_NATIVE_CLASS,
        name: TEXT_EXPANSION_NATIVE_TEST,
        status: 'unavailable',
        failureMarkers: []
      }
    };
  }
  return {
    schemaVersion: 1,
    type: 'openburnbar.linux.text-expansion-native-persistence',
    source,
    ...targetCaseEvidence(xml)
  };
}

export function writeTextExpansionNativeEvidence(evidenceDirectory) {
  const sourcePath = path.join(evidenceDirectory, TEXT_EXPANSION_NATIVE_SOURCE);
  let receipt;
  try {
    receipt = deriveTextExpansionNativeEvidence(fs.readFileSync(sourcePath, 'utf8'));
  } catch (error) {
    receipt = deriveTextExpansionNativeEvidence('', TEXT_EXPANSION_NATIVE_SOURCE);
    receipt.error = error?.code === 'ENOENT' ? 'source_missing' : 'source_unreadable';
  }
  fs.writeFileSync(
    path.join(evidenceDirectory, TEXT_EXPANSION_NATIVE_RECEIPT),
    JSON.stringify({ generatedAt: new Date().toISOString(), ...receipt }, null, 2) + '\n'
  );
  return receipt;
}
