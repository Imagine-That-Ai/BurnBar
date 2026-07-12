#!/usr/bin/env node
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
import {
  expectedLinuxReleaseIdentity,
  packageVersion,
  parseLinuxReleaseTag,
  repoRoot
} from './lib/linux-release-common.mjs';

export function resolveLinuxReleaseBinding({
  eventName,
  ref,
  refName,
  headCommit,
  tagCommit,
  manifestVersion,
  reachableFromMain
}) {
  if (!['push', 'workflow_dispatch'].includes(eventName)) {
    throw new Error(`Unsupported Linux release event: ${eventName}`);
  }
  if (!ref?.startsWith('refs/tags/')) {
    throw new Error(`Linux releases must run from a pre-existing linux-v* tag, received: ${ref || '<empty>'}`);
  }

  const tag = ref.slice('refs/tags/'.length);
  const version = parseLinuxReleaseTag(tag);
  if (refName !== tag) {
    throw new Error(`GitHub ref name drifted: ref=${ref}, refName=${refName}`);
  }
  if (manifestVersion !== version) {
    throw new Error(`Linux package version ${manifestVersion} does not match release tag version ${version}`);
  }
  if (!tagCommit || headCommit !== tagCommit) {
    throw new Error(`Release checkout is not tag-bound: HEAD=${headCommit || '<empty>'}, ${ref}=${tagCommit || '<empty>'}`);
  }
  if (!reachableFromMain) {
    throw new Error(`Linux release commit ${tagCommit} is not reachable from origin/main`);
  }

  return {
    version,
    tag,
    ref,
    commit: tagCommit,
    prerelease: version.split('+', 1)[0].includes('-'),
    expectedCosignIdentity: expectedLinuxReleaseIdentity(ref)
  };
}

function git(args, options = {}) {
  return execFileSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    ...options
  }).trim();
}

function resolveFromEnvironment() {
  const ref = process.env.GITHUB_REF ?? '';
  const tagCommit = git(['rev-list', '-n', '1', `${ref}^{commit}`]);
  const ancestry = spawnSync('git', ['merge-base', '--is-ancestor', tagCommit, 'origin/main'], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  if (ancestry.status !== 0 && ancestry.status !== 1) {
    throw new Error(`Unable to verify release commit reachability from origin/main: ${ancestry.stderr.trim()}`);
  }
  return resolveLinuxReleaseBinding({
    eventName: process.env.GITHUB_EVENT_NAME ?? '',
    ref,
    refName: process.env.GITHUB_REF_NAME ?? '',
    headCommit: git(['rev-parse', 'HEAD']),
    tagCommit,
    manifestVersion: packageVersion(),
    reachableFromMain: ancestry.status === 0
  });
}

function writeGitHubOutputs(binding, outputPath) {
  const outputs = {
    version: binding.version,
    tag: binding.tag,
    ref: binding.ref,
    commit: binding.commit,
    prerelease: String(binding.prerelease),
    expected_cosign_identity: binding.expectedCosignIdentity
  };
  fs.appendFileSync(outputPath, `${Object.entries(outputs).map(([key, value]) => `${key}=${value}`).join('\n')}\n`, 'utf8');
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  try {
    const binding = resolveFromEnvironment();
    if (process.env.GITHUB_OUTPUT) writeGitHubOutputs(binding, process.env.GITHUB_OUTPUT);
    console.log(JSON.stringify(binding, null, 2));
  } catch (error) {
    console.error(`Linux release binding failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
