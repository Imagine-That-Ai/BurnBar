#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const TAG = /^linux-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const MARKER = /^OpenBurnBar-Release-Run: [1-9][0-9]*:[1-9][0-9]*$/u;
const REPOSITORY = 'Imagine-That-Ai/BurnBar';
const VIEW_FIELDS = 'databaseId,tagName,body,isDraft';

function defaultRun(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', env: process.env });
  return { exitCode: result.status ?? 1, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

const defaultSleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function validateOptions(options) {
  if (!TAG.test(options.tag ?? '')) throw new Error('Linux release cleanup tag is invalid');
  if (!MARKER.test(options.marker ?? '')) throw new Error('Linux release cleanup ownership marker is invalid');
  if (options.repository !== REPOSITORY) throw new Error(`Linux release cleanup repository must be ${REPOSITORY}`);
  if (!Number.isSafeInteger(options.maxAttempts) || options.maxAttempts < 2 || options.maxAttempts > 20) {
    throw new Error('Linux release cleanup maxAttempts must be between 2 and 20');
  }
  if (!Number.isSafeInteger(options.absenceObservations) || options.absenceObservations < 2
      || options.absenceObservations > options.maxAttempts) {
    throw new Error('Linux release cleanup absenceObservations must be between 2 and maxAttempts');
  }
  if (!Number.isSafeInteger(options.retryDelayMs) || options.retryDelayMs < 1 || options.retryDelayMs > 60_000) {
    throw new Error('Linux release cleanup retryDelayMs must be between 1 and 60000');
  }
}

function validResult(result) {
  return result && Number.isSafeInteger(result.exitCode) && typeof result.stdout === 'string'
    && typeof result.stderr === 'string';
}

function containsMarker(body, marker) {
  return body.split(/\r?\n/u).includes(marker);
}

function parseView(result, tag, marker) {
  if (!validResult(result)) return { state: 'error', message: 'gh release view returned an invalid process result' };
  if (result.exitCode !== 0) {
    const stderr = result.stderr.trim();
    if (/(?:release not found|no release found(?: matching[^\n]*)?|could not resolve to a release with the tag name|\(HTTP 404\))/iu.test(stderr)) {
      return { state: 'absent' };
    }
    return { state: 'error', message: stderr || `gh release view exited ${result.exitCode}` };
  }
  let release;
  try {
    release = JSON.parse(result.stdout);
  } catch {
    return { state: 'error', message: 'gh release view returned malformed JSON' };
  }
  if (!release || !Number.isSafeInteger(release.databaseId) || release.databaseId <= 0
      || release.tagName !== tag || typeof release.body !== 'string' || typeof release.isDraft !== 'boolean') {
    return { state: 'error', message: 'gh release view returned a malformed release identity' };
  }
  return {
    state: containsMarker(release.body, marker) ? 'owned' : 'unowned',
    id: release.databaseId,
    draft: release.isDraft
  };
}

function parsePublishedLookup(result, tag, marker) {
  if (!validResult(result)) return { state: 'error', message: 'GitHub published release lookup returned an invalid process result' };
  if (result.exitCode !== 0) {
    if (/\(HTTP 404\)/u.test(result.stderr)) return { state: 'absent' };
    return { state: 'error', message: result.stderr.trim() || `gh api exited ${result.exitCode}` };
  }
  let release;
  try {
    release = JSON.parse(result.stdout);
  } catch {
    return { state: 'error', message: 'GitHub published release lookup returned malformed JSON' };
  }
  if (!release || !Number.isSafeInteger(release.id) || release.id <= 0 || release.tag_name !== tag
      || typeof release.body !== 'string' || release.draft !== false) {
    return { state: 'error', message: 'GitHub published release lookup returned a malformed release identity' };
  }
  return {
    state: containsMarker(release.body, marker) ? 'owned' : 'unowned',
    id: release.id,
    draft: false
  };
}

function combineObservation(view, published) {
  if (view.state === 'unowned' || published.state === 'unowned') {
    return { state: 'unowned', foundId: view.id ?? published.id ?? null };
  }
  if (view.state === 'error' || published.state === 'error') {
    return {
      state: 'ambiguous',
      foundId: view.id ?? published.id ?? null,
      message: [view.message, published.message].filter(Boolean).join('; ') || 'release lookup was ambiguous'
    };
  }
  if (view.state === 'absent' && published.state === 'absent') return { state: 'absent' };
  if (view.state === 'absent') {
    return { state: 'ambiguous', foundId: published.id ?? null,
      message: 'draft/published release discovery sources disagree' };
  }
  if (view.draft) {
    if (published.state !== 'absent') {
      return { state: 'ambiguous', foundId: view.id,
        message: 'draft release unexpectedly appeared in the published lookup' };
    }
    return { state: 'owned', id: view.id, draft: true };
  }
  if (published.state !== 'owned' || published.id !== view.id) {
    return { state: 'ambiguous', foundId: view.id,
      message: 'published release discovery sources disagree on immutable release ID' };
  }
  return { state: 'owned', id: view.id, draft: false };
}

export async function cleanupLinuxGitHubRelease(options, runImpl = defaultRun, sleepImpl = defaultSleep) {
  validateOptions(options);
  const publishedEndpoint = `repos/${options.repository}/releases/tags/${options.tag}`;
  const observe = () => combineObservation(
    parseView(runImpl('gh', [
      'release', 'view', options.tag, '--repo', options.repository, '--json', VIEW_FIELDS
    ]), options.tag, options.marker),
    parsePublishedLookup(runImpl('gh', ['api', publishedEndpoint]), options.tag, options.marker)
  );
  const wait = () => sleepImpl(options.retryDelayMs);

  let consecutiveAbsence = 0;
  let observations = 0;
  let owned = null;
  let lastAmbiguity = null;
  for (; observations < options.maxAttempts; observations += 1) {
    const observation = observe();
    if (observation.state === 'unowned') throw new Error('refusing to delete an unowned Linux release');
    if (observation.state === 'owned') {
      consecutiveAbsence = 0;
      owned = observation;
      observations += 1;
      break;
    }
    if (observation.state === 'absent') {
      consecutiveAbsence += 1;
      lastAmbiguity = null;
      if (consecutiveAbsence >= options.absenceObservations) {
        return { passed: true, deleted: false, releaseId: null, observations: observations + 1,
          consecutiveAbsence };
      }
    } else {
      consecutiveAbsence = 0;
      lastAmbiguity = observation.message;
    }
    if (observations + 1 < options.maxAttempts) await wait();
  }
  if (!owned) {
    throw new Error(`unable to prove the partial Linux release absent${lastAmbiguity ? `: ${lastAmbiguity}` : ''}`);
  }

  const releaseId = owned.id;
  let deleteAttempted = false;
  consecutiveAbsence = 0;
  lastAmbiguity = null;
  for (let attempt = 1; attempt <= options.maxAttempts; attempt += 1) {
    if (attempt === 1 || owned) {
      runImpl('gh', ['api', '--method', 'DELETE', `repos/${options.repository}/releases/${releaseId}`]);
      deleteAttempted = true;
      owned = null;
    }
    const observation = observe();
    observations += 1;
    if (observation.state === 'unowned'
        || (observation.state === 'owned' && observation.id !== releaseId)
        || (observation.state === 'ambiguous' && observation.foundId !== null
          && observation.foundId !== undefined && observation.foundId !== releaseId)) {
      throw new Error('release ownership changed during cleanup');
    }
    if (observation.state === 'owned') {
      consecutiveAbsence = 0;
      owned = observation;
      lastAmbiguity = null;
    } else if (observation.state === 'absent') {
      consecutiveAbsence += 1;
      lastAmbiguity = null;
      if (consecutiveAbsence >= options.absenceObservations) {
        return { passed: true, deleted: deleteAttempted, releaseId, observations, consecutiveAbsence };
      }
    } else {
      consecutiveAbsence = 0;
      lastAmbiguity = observation.message;
    }
    if (attempt < options.maxAttempts) await wait();
  }
  throw new Error(lastAmbiguity
    ? `unable to prove the run-owned Linux release absent: ${lastAmbiguity}`
    : 'run-owned Linux release still exists after cleanup retries');
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!['--tag', '--marker'].includes(argument)) throw new Error(`unexpected argument: ${argument}`);
    const value = argv[++index];
    if (!value) throw new Error(`missing value for ${argument}`);
    values[argument.slice(2)] = value;
  }
  return values;
}

async function main() {
  if (!process.env.GH_TOKEN) throw new Error('GH_TOKEN is required for Linux release cleanup');
  const args = parseArgs(process.argv.slice(2));
  const result = await cleanupLinuxGitHubRelease({
    tag: args.tag,
    marker: args.marker,
    repository: process.env.GITHUB_REPOSITORY,
    maxAttempts: 8,
    absenceObservations: 3,
    retryDelayMs: 2_000
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
