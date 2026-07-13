import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { captureP39MacOSOracle, parseArguments } from './capture-p39-macos-oracle.mjs';

const HEAD = 'a'.repeat(40);
const RUN_ID = '123456789';

test('macOS oracle capture rejects missing producer configuration and malformed arguments', () => {
  assert.throws(() => parseArguments([]));
  assert.throws(() => parseArguments(['--input-root', '.', '--target-head', 'A'.repeat(40), '--run-id', RUN_ID]));
  assert.throws(() => parseArguments(['--input-root', '.', '--target-head', HEAD, '--run-id', '0']));
  const original = process.env.P39_MACOS_ORACLE_COMMAND_JSON;
  delete process.env.P39_MACOS_ORACLE_COMMAND_JSON;
  try {
    assert.throws(() => captureP39MacOSOracle({
      inputRoot: path.join(process.cwd(), 'docs/linux-port/evidence/product-parity-inputs/P-39', 'macos-oracle-test'),
      targetHead: HEAD,
      runId: RUN_ID
    }), /P39_MACOS_ORACLE_COMMAND_JSON is required/u);
  } finally {
    if (original === undefined) delete process.env.P39_MACOS_ORACLE_COMMAND_JSON;
    else process.env.P39_MACOS_ORACLE_COMMAND_JSON = original;
  }
});

test('macOS oracle capture copies only the three producer-owned regular files', () => {
  const inputRoot = path.join(process.cwd(), 'docs/linux-port/evidence/product-parity-inputs/P-39', `macos-oracle-test-${process.pid}`);
  const command = [process.execPath, '-e', [
    "const fs=require('node:fs');",
    "const root=process.env.OPENBURNBAR_P39_MACOS_ORACLE_OUT;",
    "fs.writeFileSync(root+'/p39-corpus.json','{}\\n');",
    "fs.writeFileSync(root+'/p39-macos-oracle.json','{}\\n');",
    "fs.writeFileSync(root+'/p39-macos-binary.bin',Buffer.from('oracle'));"
  ].join('')];
  try {
    const result = captureP39MacOSOracle({ inputRoot, targetHead: HEAD, runId: RUN_ID, command });
    assert.deepEqual(result.files, ['p39-corpus.json', 'p39-macos-oracle.json', 'p39-macos-binary.bin']);
    for (const file of result.files) assert.equal(fs.lstatSync(path.join(inputRoot, file)).isFile(), true);
  } finally {
    fs.rmSync(inputRoot, { recursive: true, force: true });
  }
});

test('macOS oracle capture rejects producer symlinks and forbidden fixture names', () => {
  const inputRoot = path.join(process.cwd(), 'docs/linux-port/evidence/product-parity-inputs/P-39', `macos-oracle-test-${process.pid}-symlink`);
  const command = [process.execPath, '-e', [
    "const fs=require('node:fs');const root=process.env.OPENBURNBAR_P39_MACOS_ORACLE_OUT;",
    "fs.writeFileSync(root+'/p39-corpus.json','{}');fs.writeFileSync(root+'/p39-macos-oracle.json','{}');",
    "fs.symlinkSync('/etc/hosts',root+'/p39-macos-binary.bin');"
  ].join('')];
  try {
    assert.throws(() => captureP39MacOSOracle({ inputRoot, targetHead: HEAD, runId: RUN_ID, command }), /regular file/u);
  } finally {
    fs.rmSync(inputRoot, { recursive: true, force: true });
  }
});
