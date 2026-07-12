import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { runArchive } from './export-candidate.mjs';

function git(cwd, ...args) {
  execFileSync('git', args, { cwd, stdio: 'pipe' });
}

test('runArchive preserves Git blob bytes when checkout autocrlf is enabled', async () => {
  const root = await mkdtemp(join(tmpdir(), 'openburnbar-candidate-export-'));
  const extracted = join(root, 'extracted');
  const archive = join(root, 'candidate.tar');
  const expected = Buffer.from('first line\nsecond line\n', 'utf8');

  git(root, 'init', '--quiet');
  git(root, 'config', 'user.email', 'candidate-export@test.invalid');
  git(root, 'config', 'user.name', 'Candidate Export Test');
  git(root, 'config', 'core.autocrlf', 'true');
  await writeFile(join(root, 'sample.txt'), expected);
  git(root, 'add', 'sample.txt');
  git(root, 'commit', '--quiet', '-m', 'fixture');

  await runArchive('HEAD', archive, root);
  await mkdir(extracted);
  execFileSync('tar', ['-xf', archive, '-C', extracted], { stdio: 'pipe' });

  assert.deepEqual(await readFile(join(extracted, 'BurnBar', 'sample.txt')), expected);
});
