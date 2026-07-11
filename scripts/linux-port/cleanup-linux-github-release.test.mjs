import assert from 'node:assert/strict';
import test from 'node:test';
import { cleanupLinuxGitHubRelease } from './cleanup-linux-github-release.mjs';

const options = {
  tag: 'linux-v1.2.3',
  marker: 'OpenBurnBar-Release-Run: 123:2',
  repository: 'Imagine-That-Ai/BurnBar',
  maxAttempts: 6,
  absenceObservations: 3,
  retryDelayMs: 25
};

const viewAbsent = () => ({ exitCode: 1, stdout: '', stderr: 'release not found' });
const restAbsent = () => ({ exitCode: 1, stdout: '', stderr: 'gh: Not Found (HTTP 404)' });
const viewRelease = ({ id = 41, marker = options.marker, draft = true } = {}) => ({
  exitCode: 0,
  stdout: JSON.stringify({ databaseId: id, tagName: options.tag, body: `notes\n${marker}\n`, isDraft: draft }),
  stderr: ''
});
const restRelease = ({ id = 41, marker = options.marker } = {}) => ({
  exitCode: 0,
  stdout: JSON.stringify({ id, tag_name: options.tag, body: `notes\n${marker}\n`, draft: false }),
  stderr: ''
});

function commandKind(args) {
  if (args[0] === 'release' && args[1] === 'view') return 'view';
  if (args[0] === 'api' && args[1] === '--method') return 'delete';
  if (args[0] === 'api') return 'rest';
  throw new Error(`unexpected gh arguments: ${args.join(' ')}`);
}

function scriptedRunner(observations, deleteResult = { exitCode: 0, stdout: '', stderr: '' }) {
  const calls = [];
  let observationIndex = 0;
  let activeObservation = null;
  const run = (command, args) => {
    calls.push([command, ...args]);
    const kind = commandKind(args);
    if (kind === 'delete') return typeof deleteResult === 'function' ? deleteResult() : deleteResult;
    if (kind === 'view') activeObservation = observations[Math.min(observationIndex, observations.length - 1)];
    const result = activeObservation[kind];
    if (kind === 'rest') observationIndex += 1;
    return result;
  };
  return { calls, run, get observationsRead() { return observationIndex; } };
}

const absentObservation = () => ({ view: viewAbsent(), rest: restAbsent() });
const draftObservation = (overrides) => ({ view: viewRelease({ ...overrides, draft: true }), rest: restAbsent() });
const publishedObservation = (overrides) => ({
  view: viewRelease({ ...overrides, draft: false }),
  rest: restRelease(overrides)
});

test('cleanup requires repeated dual absence before certifying no release', async () => {
  const runner = scriptedRunner([absentObservation(), absentObservation(), absentObservation()]);
  const sleeps = [];
  const result = await cleanupLinuxGitHubRelease(options, runner.run, async (delay) => sleeps.push(delay));
  assert.deepEqual(result, {
    passed: true,
    deleted: false,
    releaseId: null,
    observations: 3,
    consecutiveAbsence: 3
  });
  assert.equal(runner.calls.filter((call) => call[1] === 'release').length, 3);
  assert.equal(runner.calls.filter((call) => call[1] === 'api').length, 3);
  assert.deepEqual(sleeps, [25, 25]);
});

test('draft appearing after an initial 404 is discovered, deleted by immutable ID, and repeatedly proven absent', async () => {
  const runner = scriptedRunner([
    absentObservation(),
    draftObservation({ id: 73 }),
    absentObservation(),
    absentObservation(),
    absentObservation()
  ], { exitCode: 1, stdout: '', stderr: 'delete response lost after commit' });
  const result = await cleanupLinuxGitHubRelease(options, runner.run, async () => {});
  assert.equal(result.passed, true);
  assert.equal(result.deleted, true);
  assert.equal(result.releaseId, 73);
  assert.equal(result.consecutiveAbsence, 3);
  const deletes = runner.calls.filter((call) => call[2] === '--method');
  assert.deepEqual(deletes, [[
    'gh', 'api', '--method', 'DELETE', 'repos/Imagine-That-Ai/BurnBar/releases/73'
  ]]);
  assert.equal(runner.calls.some((call) => call[1] === 'release' && call[2] === 'delete'), false);
});

test('published release requires matching view and REST identities before deletion', async () => {
  const runner = scriptedRunner([
    publishedObservation({ id: 91 }),
    absentObservation(),
    absentObservation(),
    absentObservation()
  ]);
  const result = await cleanupLinuxGitHubRelease(options, runner.run, async () => {});
  assert.equal(result.passed, true);
  assert.equal(result.releaseId, 91);
  assert.equal(runner.calls.filter((call) => call[2] === '--method').length, 1);
  assert.ok(runner.calls.some((call) => call.includes('databaseId,tagName,body,isDraft')));
});

test('any found or ambiguous observation resets the consecutive absence proof', async () => {
  const runner = scriptedRunner([
    draftObservation({ id: 41 }),
    absentObservation(),
    { view: { exitCode: 1, stdout: '', stderr: 'temporary GraphQL failure' }, rest: restAbsent() },
    absentObservation(),
    absentObservation(),
    absentObservation()
  ]);
  const result = await cleanupLinuxGitHubRelease({ ...options, maxAttempts: 7 }, runner.run, async () => {});
  assert.equal(result.passed, true);
  assert.equal(result.consecutiveAbsence, 3);
  assert.equal(runner.observationsRead, 6);
});

test('cleanup rejects initial unowned releases and any ownership or immutable-ID change', async () => {
  const unowned = scriptedRunner([draftObservation({ marker: 'OpenBurnBar-Release-Run: 999:1' })]);
  await assert.rejects(() => cleanupLinuxGitHubRelease(options, unowned.run, async () => {}), /unowned/u);
  assert.equal(unowned.calls.some((call) => call[2] === '--method'), false);

  for (const replacement of [
    draftObservation({ id: 41, marker: 'OpenBurnBar-Release-Run: 999:1' }),
    draftObservation({ id: 42 })
  ]) {
    const runner = scriptedRunner([draftObservation({ id: 41 }), replacement]);
    await assert.rejects(() => cleanupLinuxGitHubRelease({ ...options, maxAttempts: 2, absenceObservations: 2 },
      runner.run, async () => {}), /ownership changed/u);
  }
});

test('persistent discovery ambiguity and persistent owned presence fail closed', async () => {
  const ambiguous = scriptedRunner([{
    view: { exitCode: 1, stdout: '', stderr: 'network unavailable' },
    rest: restAbsent()
  }]);
  await assert.rejects(() => cleanupLinuxGitHubRelease(options, ambiguous.run, async () => {}),
    /unable to prove.*network unavailable/u);

  const persistent = scriptedRunner([draftObservation({ id: 41 })], {
    exitCode: 1, stdout: '', stderr: 'delete failed'
  });
  await assert.rejects(() => cleanupLinuxGitHubRelease(options, persistent.run, async () => {}), /still exists/u);
  assert.equal(persistent.calls.filter((call) => call[2] === '--method').length, options.maxAttempts);

  const postDeleteAmbiguity = scriptedRunner([
    draftObservation({ id: 41 }),
    { view: { exitCode: 1, stdout: '', stderr: 'GraphQL unavailable' }, rest: restAbsent() }
  ]);
  await assert.rejects(() => cleanupLinuxGitHubRelease({ ...options, maxAttempts: 3 },
    postDeleteAmbiguity.run, async () => {}), /unable to prove.*GraphQL unavailable/u);
});

test('partial draft discovery never accepts published-only REST absence as full absence', async () => {
  const runner = scriptedRunner([
    draftObservation({ id: 55 }),
    absentObservation(),
    absentObservation(),
    absentObservation()
  ]);
  const result = await cleanupLinuxGitHubRelease(options, runner.run, async () => {});
  assert.equal(result.releaseId, 55);
  assert.equal(result.deleted, true);
});

test('cleanup validates exact repository, tag, marker, absence count, retry count, and delay before gh access', async () => {
  let calls = 0;
  for (const override of [
    { repository: 'attacker/repo' },
    { tag: 'v1.2.3' },
    { marker: 'OpenBurnBar-Release-Run: nope' },
    { maxAttempts: 1 },
    { maxAttempts: 4, absenceObservations: 1 },
    { maxAttempts: 2, absenceObservations: 3 },
    { retryDelayMs: 0 },
    { retryDelayMs: 60_001 }
  ]) {
    await assert.rejects(() => cleanupLinuxGitHubRelease({ ...options, ...override }, () => {
      calls += 1;
      return viewAbsent();
    }), /invalid|must be|between/u);
  }
  assert.equal(calls, 0);
});
