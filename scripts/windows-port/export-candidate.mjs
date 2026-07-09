#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '..', '..');

function usage() {
  console.error(`Usage: node scripts/windows-port/export-candidate.mjs --output-dir <dir> [--ref <git-ref>]`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = { ref: 'HEAD', outputDir: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--output-dir') {
      args.outputDir = argv[++i] ?? '';
    } else if (arg === '--ref') {
      args.ref = argv[++i] ?? '';
    } else if (arg === '--help' || arg === '-h') {
      usage();
    } else {
      console.error(`Unknown argument: ${arg}`);
      usage();
    }
  }
  if (!args.outputDir || !args.ref) usage();
  return args;
}

function git(args, options = {}) {
  const spawnOptions = {
    cwd: repoRoot,
    maxBuffer: options.maxBuffer ?? 128 * 1024 * 1024,
  };
  if (options.encoding !== 'buffer') {
    spawnOptions.encoding = options.encoding ?? 'utf8';
  }
  const result = spawnSync('git', args, spawnOptions);
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${result.stderr || result.stdout}`);
  }
  return result.stdout;
}

function sha256Hex(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

function canonicalJson(value) {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(',')}]`;
  }
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
}

function parseTreeRecords(buffer) {
  const records = [];
  let offset = 0;
  while (offset < buffer.length) {
    const end = buffer.indexOf(0, offset);
    if (end < 0) break;
    const record = buffer.subarray(offset, end);
    offset = end + 1;
    if (record.length === 0) continue;

    const tab = record.indexOf(9);
    const meta = record.subarray(0, tab).toString('utf8');
    const path = record.subarray(tab + 1).toString('utf8');
    const [mode, type, objectId] = meta.split(' ');
    if (type !== 'blob') continue;
    records.push({ path, mode, objectId });
  }
  return records.sort((a, b) => a.path.localeCompare(b.path));
}

function hashBlobObjects(records) {
  const input = records.map((record) => `${record.objectId}\n`).join('');
  const child = spawnSync('git', ['cat-file', '--batch'], {
    cwd: repoRoot,
    input,
    maxBuffer: 1024 * 1024 * 1024,
  });
  if (child.status !== 0) {
    throw new Error(`git cat-file --batch failed: ${child.stderr.toString('utf8')}`);
  }

  const output = child.stdout;
  const hashed = [];
  let offset = 0;
  for (const record of records) {
    const headerEnd = output.indexOf(10, offset);
    if (headerEnd < 0) throw new Error(`Missing cat-file header for ${record.path}`);
    const header = output.subarray(offset, headerEnd).toString('utf8');
    const [objectId, type, sizeText] = header.split(' ');
    const size = Number.parseInt(sizeText, 10);
    if (objectId !== record.objectId || type !== 'blob' || !Number.isFinite(size)) {
      throw new Error(`Unexpected cat-file header for ${record.path}: ${header}`);
    }
    const contentStart = headerEnd + 1;
    const contentEnd = contentStart + size;
    const content = output.subarray(contentStart, contentEnd);
    hashed.push({
      path: record.path,
      mode: record.mode,
      gitBlobSha1: record.objectId,
      size,
      sha256: sha256Hex(content),
    });
    offset = contentEnd + 1;
  }
  return hashed;
}

async function runArchive(ref, archivePath) {
  await new Promise((resolvePromise, reject) => {
    const child = spawn('git', ['archive', '--format=tar', '--prefix=BurnBar/', '-o', archivePath, ref], {
      cwd: repoRoot,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolvePromise();
      else reject(new Error(`git archive failed with exit ${code}: ${stderr}`));
    });
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const outputDir = resolve(args.outputDir);
  await mkdir(outputDir, { recursive: true });

  const commit = git(['rev-parse', `${args.ref}^{commit}`]).trim();
  const tree = git(['rev-parse', `${commit}^{tree}`]).trim();
  const branch = git(['branch', '--show-current']).trim();
  const parentCommits = git(['show', '-s', '--format=%P', commit]).trim().split(/\s+/).filter(Boolean);
  const commitDate = git(['show', '-s', '--format=%cI', commit]).trim();
  const treeBuffer = git(['ls-tree', '-r', '-z', '--full-tree', commit], { encoding: 'buffer' });
  const files = hashBlobObjects(parseTreeRecords(treeBuffer));

  const archiveName = `openburnbar-candidate-${commit.slice(0, 12)}.tar`;
  const archivePath = join(outputDir, archiveName);
  await runArchive(commit, archivePath);
  const archiveBytes = await readFile(archivePath);

  const manifestPayload = {
    schema: 'openburnbar.windows.candidate-export.v1',
    source: {
      commit,
      tree,
      parentCommits,
      branch,
      ref: args.ref,
      commitDate,
    },
    archive: {
      fileName: archiveName,
      format: 'git-archive-tar',
      prefix: 'BurnBar/',
      sha256: sha256Hex(archiveBytes),
      size: archiveBytes.length,
    },
    files,
  };
  const payloadJson = `${canonicalJson(manifestPayload)}\n`;
  const manifest = {
    ...manifestPayload,
    manifestPayloadSha256: sha256Hex(Buffer.from(payloadJson, 'utf8')),
  };
  const manifestJson = `${canonicalJson(manifest)}\n`;
  const manifestName = `openburnbar-candidate-${commit.slice(0, 12)}.manifest.json`;
  const manifestPath = join(outputDir, manifestName);
  await writeFile(manifestPath, manifestJson, 'utf8');

  const summary = {
    exportedAt: new Date().toISOString(),
    commit,
    tree,
    fileCount: files.length,
    archivePath,
    archiveSha256: manifest.archive.sha256,
    archiveSize: manifest.archive.size,
    manifestPath,
    manifestSha256: sha256Hex(Buffer.from(manifestJson, 'utf8')),
    manifestPayloadSha256: manifest.manifestPayloadSha256,
  };
  await writeFile(join(outputDir, 'export-summary.json'), `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(summary, null, 2));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
