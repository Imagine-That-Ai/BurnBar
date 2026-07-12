#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repoRoot } from './lib/linux-release-common.mjs';

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

export function resolveLinuxReleaseVersion(input) {
  const failures = [];
  const eventName = input.eventName;
  const tagMatch = /^refs\/tags\/linux-v(.+)$/.exec(input.ref ?? '');
  let version = null;
  let publishAllowed = false;

  if (eventName === 'push') {
    if (!tagMatch) failures.push('Linux tag releases require refs/tags/linux-vX.Y.Z.');
    version = tagMatch?.[1] ?? null;
    publishAllowed = tagMatch !== null;
  } else if (eventName === 'workflow_dispatch') {
    version = input.inputVersion?.trim() || null;
    if (!version) failures.push('Manual Linux release version is required.');
    if (tagMatch && tagMatch[1] !== version) failures.push('Manual version does not match the selected Linux tag.');
    publishAllowed = tagMatch?.[1] === version;
  } else {
    failures.push(`Unsupported Linux release event: ${eventName ?? '<missing>'}.`);
  }

  if (version && !SEMVER.test(version)) failures.push(`Linux release version is not strict semver: ${version}.`);
  for (const [label, declared] of [
    ['package.json', input.packageVersion],
    ['tauri.conf.json', input.tauriVersion]
  ]) {
    if (version && declared !== version) failures.push(`${label} version ${declared ?? '<missing>'} does not match ${version}.`);
  }
  return { passed: failures.length === 0, version, tag: version ? `linux-v${version}` : null, publishAllowed, failures };
}

function main() {
  const packageJson = JSON.parse(fs.readFileSync(path.join(repoRoot, 'apps/linux-desktop/package.json'), 'utf8'));
  const tauri = JSON.parse(fs.readFileSync(path.join(repoRoot, 'apps/linux-desktop/src-tauri/tauri.conf.json'), 'utf8'));
  const result = resolveLinuxReleaseVersion({
    eventName: process.env.GITHUB_EVENT_NAME,
    ref: process.env.GITHUB_REF,
    inputVersion: process.env.INPUT_VERSION,
    packageVersion: packageJson.version,
    tauriVersion: tauri.version
  });
  if (process.argv.includes('--github-output') && process.env.GITHUB_OUTPUT && result.passed) {
    fs.appendFileSync(
      process.env.GITHUB_OUTPUT,
      `version=${result.version}\ntag=${result.tag}\npublish_allowed=${result.publishAllowed}\n`
    );
  }
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.passed ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
