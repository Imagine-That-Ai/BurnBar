#!/usr/bin/env node
import { fileMentions, isObject, readJson, runCheckCli } from './lib/check-support.mjs';
import { repoRoot } from './lib/repo-root.mjs';

export const PRODUCT_FIXTURES = [
  'docs/mobile-parity/fixtures/product/pulse-burn-vectors.json',
  'docs/mobile-parity/fixtures/product/streams-inbox-vectors.json',
  'docs/mobile-parity/fixtures/product/hermes-mercury-computer-use-vectors.json'
];

export const PRODUCT_TEST_FILES = {
  swift: [
    'OpenBurnBarCore/Tests/OpenBurnBarCoreTests/MobileProductParityTests.swift',
    'OpenBurnBarCore/Tests/OpenBurnBarCoreTests/MobileHermesMercuryComputerUseParityTests.swift',
    'OpenBurnBarMobileTests/PulseBurnProductVectorTests.swift'
  ],
  kotlin: [
    'android/app/src/test/java/com/openburnbar/data/policy/MobileProductParityTest.kt',
    'android/app/src/test/java/com/openburnbar/data/policy/MobileHermesMercuryComputerUseParityTest.kt'
  ]
};

const WINDOW_SCOPES = new Set(['minute', 'hour', 'day', 'week', 'month']);
const LOAD_PRESENTATIONS = new Set(['loading', 'failed', 'empty', 'live', 'stale-refresh-failed']);
const LIST_PRESENTATIONS = new Set(['loading', 'failed', 'empty', 'locked', 'ready', 'paginating']);
const DISPOSITIONS = new Set(['real', 'removed', 'gated']);
const STREAM_TERMINALS = new Set(['streaming', 'stopped', 'cancelled', 'error', 'completed']);
const ATTACHMENT_DISPOSITIONS = new Set(['accepted', 'rejected']);
const DEEP_LINKS = new Set(['loaded', 'missing', 'invalid']);
const INVITE_ACKS = new Set(['paired', 'mismatch', 'denied']);
const SESSION_PRESENTATIONS = new Set(['idle', 'connected', 'reconnecting', 'denied', 'failed']);
const SAFETY_DECISIONS = new Set(['allow', 'reject']);

function readProductFixture(root, relative) {
  return readJson(root, relative, 'missing product fixture:');
}

function validatePulseBurn(fixture, failures) {
  if (fixture.schemaVersion !== 1) failures.push('pulse-burn schemaVersion must be 1');
  if (fixture.id !== 'openburnbar-mobile-pulse-burn-vectors-v1') {
    failures.push('pulse-burn id must be openburnbar-mobile-pulse-burn-vectors-v1');
  }
  if (!String(fixture.sourceOracle ?? '').includes('PulseWindowMetricBuilder')) {
    failures.push('pulse-burn sourceOracle must name PulseWindowMetricBuilder');
  }
  if (!Array.isArray(fixture.vectors) || fixture.vectors.length === 0) {
    failures.push('pulse-burn vectors are required');
    return [];
  }
  const ids = [];
  for (const vector of fixture.vectors) {
    if (!vector?.id) {
      failures.push('pulse-burn vector is missing id');
      continue;
    }
    ids.push(vector.id);
    if (!vector.kind) failures.push(`${vector.id} is missing kind`);
    if (vector.kind === 'window') {
      if (!isObject(vector.expected)) {
        failures.push(`${vector.id} expected windows are required`);
      } else {
        for (const [scope, totals] of Object.entries(vector.expected)) {
          if (!WINDOW_SCOPES.has(scope)) failures.push(`${vector.id} unknown scope ${scope}`);
          if (typeof totals.requests !== 'number' || typeof totals.tokens !== 'number' || typeof totals.costUsd !== 'number') {
            failures.push(`${vector.id}.${scope} must pin requests/tokens/costUsd`);
          }
        }
      }
    }
    if (vector.kind === 'liveQueryStart' && typeof vector.expected?.startMs !== 'number') {
      failures.push(`${vector.id} must pin expected.startMs`);
    }
    if (vector.kind === 'loadPresentation') {
      const presentation = vector.expected?.presentation;
      if (!LOAD_PRESENTATIONS.has(presentation)) {
        failures.push(`${vector.id} has unknown presentation ${presentation}`);
      }
      if (vector.failed === true && vector.expected?.looksLikeLiveZero === true) {
        failures.push(`${vector.id} failed load must not look like live zero`);
      }
    }
    if (vector.kind === 'display') {
      if (!vector.expected?.currencyHero || !vector.expected?.tokensHero) {
        failures.push(`${vector.id} must pin currency and token hero strings`);
      }
    }
    if (vector.kind === 'quotaGroup' && !Array.isArray(vector.expected?.keys)) {
      failures.push(`${vector.id} must pin expected grouping keys`);
    }
  }
  return ids;
}

function validateStreamsInbox(fixture, failures) {
  if (fixture.schemaVersion !== 1) failures.push('streams-inbox schemaVersion must be 1');
  if (fixture.id !== 'openburnbar-mobile-streams-inbox-vectors-v1') {
    failures.push('streams-inbox id must be openburnbar-mobile-streams-inbox-vectors-v1');
  }
  const ids = [];
  for (const vector of fixture.vectors ?? []) {
    if (!vector?.id) {
      failures.push('streams-inbox vector is missing id');
      continue;
    }
    ids.push(vector.id);
    if (vector.kind === 'listPresentation' && !LIST_PRESENTATIONS.has(vector.expected?.presentation)) {
      failures.push(`${vector.id} has unknown list presentation`);
    }
    if (vector.kind === 'pagination' && !isObject(vector.expected)) {
      failures.push(`${vector.id} must pin pagination expected`);
    }
    if (vector.kind === 'cardAction') {
      for (const action of vector.actions ?? []) {
        if (!DISPOSITIONS.has(action.expected)) {
          failures.push(`${vector.id} action ${action.id} has unknown disposition`);
        }
      }
    }
  }
  return ids;
}

function validateHermesMercuryComputerUse(fixture, failures) {
  if (fixture.schemaVersion !== 1) failures.push('hermes-mercury-cu schemaVersion must be 1');
  if (fixture.id !== 'openburnbar-mobile-hermes-mercury-computer-use-vectors-v1') {
    failures.push('hermes-mercury-cu id must be openburnbar-mobile-hermes-mercury-computer-use-vectors-v1');
  }
  const ids = [];
  for (const vector of fixture.vectors ?? []) {
    if (!vector?.id) {
      failures.push('hermes-mercury-cu vector is missing id');
      continue;
    }
    ids.push(vector.id);
    const expected = vector.expected;
    if (!isObject(expected)) {
      failures.push(`${vector.id} must pin expected`);
      continue;
    }
    if (vector.kind === 'streamTerminal') {
      if (!STREAM_TERMINALS.has(expected.terminal)) failures.push(`${vector.id} unknown terminal`);
      if (typeof expected.keepPartial !== 'boolean') failures.push(`${vector.id} must pin keepPartial`);
      if (typeof expected.isError !== 'boolean') failures.push(`${vector.id} must pin isError`);
      if (expected.isError === true && expected.keepPartial === true) {
        failures.push(`${vector.id} error terminal must not keep a success partial`);
      }
    }
    if (vector.kind === 'reconnectUser' && typeof expected.appendUser !== 'boolean') {
      failures.push(`${vector.id} must pin appendUser`);
    }
    if (vector.kind === 'toolCallAfterStop') {
      if (expected.renderToolCalls !== true) failures.push(`${vector.id} tool calls must still render after stop`);
      if (expected.dropEmptyAssistant === true) failures.push(`${vector.id} tool-call turn must not be dropped`);
    }
    if (vector.kind === 'attachment' && !ATTACHMENT_DISPOSITIONS.has(expected.disposition)) {
      failures.push(`${vector.id} unknown attachment disposition`);
    }
    if (vector.kind === 'deepLink') {
      if (!DEEP_LINKS.has(expected.outcome)) failures.push(`${vector.id} unknown deep-link outcome`);
      if (vector.exists === false && expected.outcome === 'loaded') {
        failures.push(`${vector.id} missing conversation must not look loaded`);
      }
    }
    if (vector.kind === 'threadIsolation' && expected.apply === true) {
      failures.push(`${vector.id} late chunk for another thread must not apply`);
    }
    if (vector.kind === 'heartbeat' && expected.intervalMs !== 60000) {
      failures.push(`${vector.id} heartbeat interval must be 60000`);
    }
    if (vector.kind === 'capability' && !Array.isArray(expected.capabilities)) {
      failures.push(`${vector.id} must pin filtered capabilities`);
    }
    if (vector.kind === 'inviteAck' && !INVITE_ACKS.has(expected.pair)) {
      failures.push(`${vector.id} unknown invite/ack pair`);
    }
    if (vector.kind === 'sessionPresentation') {
      if (!SESSION_PRESENTATIONS.has(expected.presentation)) {
        failures.push(`${vector.id} unknown session presentation`);
      }
      if (vector.denied === true && expected.presentation === 'connected') {
        failures.push(`${vector.id} denial must not look connected`);
      }
    }
    if (vector.kind === 'safetyDecision') {
      if (!SAFETY_DECISIONS.has(expected.decision)) failures.push(`${vector.id} unknown safety decision`);
      if (expected.decision !== 'reject') failures.push(`${vector.id} negative KAT must reject`);
    }
  }
  return ids;
}

export function validateMobileProductVectors(options = {}) {
  const failures = [];
  const root = options.repoRoot ?? repoRoot;
  const pulse = readProductFixture(root, options.pulsePath ?? PRODUCT_FIXTURES[0]);
  if (pulse.error) return { passed: false, failures: [pulse.error], ids: [] };
  const streams = readProductFixture(root, options.streamsPath ?? PRODUCT_FIXTURES[1]);
  if (streams.error) return { passed: false, failures: [streams.error], ids: [] };

  const hermes = readProductFixture(root, options.hermesPath ?? PRODUCT_FIXTURES[2]);
  if (hermes.error) return { passed: false, failures: [hermes.error], ids: [] };

  const ids = [
    ...validatePulseBurn(pulse.value, failures),
    ...validateStreamsInbox(streams.value, failures),
    ...validateHermesMercuryComputerUse(hermes.value, failures)
  ];
  const unique = new Set(ids);
  if (unique.size !== ids.length) failures.push('product vector ids must be unique');

  const swiftFiles = options.swiftFiles ?? PRODUCT_TEST_FILES.swift;
  const kotlinFiles = options.kotlinFiles ?? PRODUCT_TEST_FILES.kotlin;
  for (const id of unique) {
    const inSwift = swiftFiles.some((file) => fileMentions(root, file, id));
    const inKotlin = kotlinFiles.some((file) => fileMentions(root, file, id));
    if (!inSwift) failures.push(`no Swift test file references vector ${id}`);
    if (!inKotlin) failures.push(`no Kotlin test file references vector ${id}`);
  }

  return { passed: failures.length === 0, failures, ids: [...unique] };
}

runCheckCli(
  import.meta.url,
  validateMobileProductVectors,
  (result) => `mobile product vectors ok (${result.ids.length} ids)`
);
