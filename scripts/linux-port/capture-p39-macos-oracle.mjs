#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SHA_PATTERN = /^[a-f0-9]{40}$/u;
const RUN_ID_PATTERN = /^[1-9][0-9]*$/u;
const ALLOWED_FILES = Object.freeze([
  'p39-corpus.json',
  'p39-macos-oracle.json',
  'p39-macos-binary.bin'
]);
const FORBIDDEN_EVIDENCE = /(?:fixture|synthetic|mock|fake|stub)/iu;

function parseArguments(argv) {
  const expected = new Set(['--input-root', '--target-head', '--run-id']);
  const parsed = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!expected.has(flag) || value === undefined || value.startsWith('--') || parsed.has(flag)) {
      throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    }
    parsed.set(flag, value);
  }
  for (const flag of expected) if (!parsed.has(flag)) throw new Error(`${flag} is required`);
  if (!SHA_PATTERN.test(parsed.get('--target-head'))) throw new Error('--target-head must be a lowercase 40-character commit');
  if (!RUN_ID_PATTERN.test(parsed.get('--run-id'))) throw new Error('--run-id must be a positive canonical integer');
  return {
    inputRoot: path.resolve(parsed.get('--input-root')),
    targetHead: parsed.get('--target-head'),
    runId: parsed.get('--run-id')
  };
}

function commandFromEnvironment() {
  const raw = process.env.P39_MACOS_ORACLE_COMMAND_JSON;
  if (!raw) throw new Error('P39_MACOS_ORACLE_COMMAND_JSON is required; no macOS oracle may be synthesized');
  let command;
  try {
    command = JSON.parse(raw);
  } catch (error) {
    throw new Error(`P39_MACOS_ORACLE_COMMAND_JSON is invalid JSON: ${error.message}`);
  }
  if (!Array.isArray(command) || command.length === 0
      || command.some((part) => typeof part !== 'string' || part.length === 0)) {
    throw new Error('P39_MACOS_ORACLE_COMMAND_JSON must be a nonempty string array');
  }
  return command;
}

function assertRegularFile(root, relativePath) {
  if (FORBIDDEN_EVIDENCE.test(relativePath) || path.posix.normalize(relativePath) !== relativePath) {
    throw new Error(`macOS oracle path is not canonical: ${relativePath}`);
  }
  const absolute = path.join(root, relativePath);
  const stat = fs.lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`macOS oracle output is not a regular file: ${relativePath}`);
  return absolute;
}

export function captureP39MacOSOracle({ inputRoot, targetHead, runId, command = commandFromEnvironment() }) {
  const repository = fs.realpathSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..'));
  fs.mkdirSync(inputRoot, { recursive: true });
  const evidenceRoot = fs.realpathSync(inputRoot);
  const relative = path.relative(repository, evidenceRoot);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('P-39 macOS oracle input root must be inside the repository');
  }
  const outputRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p39-macos-oracle-'));
  try {
    const result = spawnSync(command[0], command.slice(1), {
      cwd: repository,
      env: {
        ...process.env,
        OPENBURNBAR_P39_MACOS_ORACLE_OUT: outputRoot,
        OPENBURNBAR_P39_TARGET_HEAD: targetHead,
        OPENBURNBAR_P39_RUN_ID: runId
      },
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024
    });
    if (result.error) throw new Error(`macOS oracle producer failed to start: ${result.error.message}`);
    if (result.status !== 0 || result.signal) {
      throw new Error(`macOS oracle producer failed (status=${result.status ?? 'null'}, signal=${result.signal ?? 'none'}): ${(result.stderr || '').trim()}`);
    }
    for (const file of ALLOWED_FILES) {
      const source = assertRegularFile(outputRoot, file);
      const target = path.join(evidenceRoot, file);
      fs.copyFileSync(source, target, fs.constants.COPYFILE_EXCL);
      assertRegularFile(evidenceRoot, file);
    }
    return { inputRoot: evidenceRoot, files: [...ALLOWED_FILES] };
  } finally {
    fs.rmSync(outputRoot, { recursive: true, force: true });
  }
}

export { parseArguments };

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    captureP39MacOSOracle(parseArguments(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`P-39 macOS oracle capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
