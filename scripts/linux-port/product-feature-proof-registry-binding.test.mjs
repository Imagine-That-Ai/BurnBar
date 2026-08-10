import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const registryPath = resolve(repoRoot, 'docs/linux-port/product-feature-proof-registry.json');

function git(args) {
  return execFileSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
}

test('all certification ownership test bindings resolve to committed test source', () => {
  const registry = JSON.parse(readFileSync(registryPath, 'utf8'));
  const entries = registry.certification;
  assert.ok(Array.isArray(entries), 'certification must be an array');
  assert.equal(entries.length, 40, `expected exactly 40 certification requirements, found ${entries.length}`);

  const bindings = [];
  for (const entry of entries) {
    const { requirementId } = entry;
    for (const component of ['validator', 'capture', 'materializer']) {
      const ownership = entry[component];
      assert.ok(ownership, `${requirementId}/${component}: ownership block is missing`);
      const nameField = component === 'validator' ? 'mutationTestName' : 'testName';
      const testName = ownership[nameField];
      const testPath = ownership.testPath;
      assert.equal(typeof testPath, 'string', `${requirementId}/${component}: testPath must be a string`);
      assert.equal(typeof testName, 'string', `${requirementId}/${component}: ${nameField} must be a string`);
      bindings.push({ requirementId, component, testPath, testName });
    }
  }

  assert.equal(bindings.length, 120, `expected exactly 120 ownership bindings, found ${bindings.length}`);

  const committedSourceByPath = new Map();
  for (const { requirementId, component, testPath, testName } of bindings) {
    const label = `${requirementId}/${component}/${testPath}/${testName}`;
    assert.doesNotThrow(
      () => git(['ls-files', '--error-unmatch', '--', testPath]),
      `${label}: testPath is not tracked by git`,
    );
    if (!committedSourceByPath.has(testPath)) {
      let source;
      assert.doesNotThrow(
        () => { source = git(['show', `HEAD:${testPath}`]); },
        `${label}: testPath is not readable from committed HEAD`,
      );
      committedSourceByPath.set(testPath, source);
    }
    const committedSource = committedSourceByPath.get(testPath);
    assert.ok(
      committedSource.includes(testName),
      `${label}: registry test name not found in committed test source`,
    );
  }
});
