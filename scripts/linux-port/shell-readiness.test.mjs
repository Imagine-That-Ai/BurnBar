import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  BACKDROP_CANVAS_SELECTOR,
  BACKDROP_CSS_SELECTOR,
  KERNEL_SWITCHER_PANEL_SELECTOR,
  KERNEL_SWITCHER_TRIGGER_SELECTOR,
  SHELL_READY_SELECTOR,
  isTransientAutomationError,
  withReadinessRetry
} from './lib/shell-readiness.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

test('the shell publishes the readiness identifiers the harness waits on', () => {
  const app = read('apps/linux-desktop/src/app/App.tsx');
  assert.match(app, /data-shell-ready=\{shellReady \? 'ready' : 'pending'\}/u);
  const switcher = read('apps/linux-desktop/src/components/KernelSwitcher.tsx');
  assert.match(switcher, /data-testid="kernel-switcher-trigger"/u);
  assert.match(switcher, /data-testid="kernel-switcher-panel"/u);
});

test('the contrast harness waits on the shared readiness contract, not raw class selectors', () => {
  const harness = read('scripts/linux-port/verify-backdrop-contrast.mjs');
  assert.match(harness, /SHELL_READY_SELECTOR/u);
  assert.match(harness, /KERNEL_SWITCHER_TRIGGER_SELECTOR/u);
  assert.match(harness, /KERNEL_SWITCHER_PANEL_SELECTOR/u);
  assert.match(harness, /withReadinessRetry/u);
  // The old fragile pattern must not come back: clicking the trigger by CSS
  // class with no readiness wait.
  assert.doesNotMatch(harness, /locator\("\.kernel-switcher-trigger"\)/u);
});

test('selectors stay in sync with the published contract', () => {
  assert.equal(SHELL_READY_SELECTOR, ".shell[data-shell-ready='ready']");
  assert.equal(KERNEL_SWITCHER_TRIGGER_SELECTOR, "[data-testid='kernel-switcher-trigger']");
  assert.equal(KERNEL_SWITCHER_PANEL_SELECTOR, "[data-testid='kernel-switcher-panel']");
  assert.match(BACKDROP_CANVAS_SELECTOR, /data-backdrop-mode='canvas'/u);
  assert.match(BACKDROP_CSS_SELECTOR, /data-backdrop-mode='css'/u);
});

test('withReadinessRetry recovers from transient failures and reports recovery', async () => {
  let calls = 0;
  const outcome = await withReadinessRetry(async () => {
    calls += 1;
    if (calls < 3) throw new Error('Timeout 30000ms exceeded while waiting for selector');
    return 'ok';
  }, { attempts: 3, delayMs: 1 });
  assert.equal(outcome.value, 'ok');
  assert.equal(outcome.attempts, 3);
  assert.equal(outcome.recovered, true);
});

test('withReadinessRetry does not retry product assertion failures', async () => {
  let calls = 0;
  await assert.rejects(
    withReadinessRetry(async () => {
      calls += 1;
      throw new Error('mesh/250: 3.9:1 contrast');
    }, { attempts: 3, delayMs: 1 }),
    /3\.9:1 contrast/u
  );
  assert.equal(calls, 1, 'a real contrast failure must fail on the first attempt');
});

test('withReadinessRetry exhausts attempts on persistent transient failures', async () => {
  let calls = 0;
  const retries = [];
  await assert.rejects(
    withReadinessRetry(async () => {
      calls += 1;
      throw new Error('Target closed');
    }, { attempts: 3, delayMs: 1, onRetry: async (error, attempt) => retries.push(attempt) }),
    /Target closed/u
  );
  assert.equal(calls, 3);
  assert.deepEqual(retries, [1, 2]);
});

test('transient classification covers automation failure shapes only', () => {
  for (const transient of [
    new Error('Timeout 45000ms exceeded'),
    new Error('page.waitForSelector: Timeout 45000ms exceeded while waiting for selector'),
    new Error('Target closed'),
    new Error('Execution context was destroyed'),
    new Error('Element is not attached to the DOM'),
    new Error('frame was detached')
  ]) {
    assert.equal(isTransientAutomationError(transient), true, transient.message);
  }
  for (const product of [
    new Error('registry audit found 12 kernels; expected at least 32'),
    new Error('aurora/mesh/250: 3.2:1 contrast'),
    new Error('emergency CSS fallback failed')
  ]) {
    assert.equal(isTransientAutomationError(product), false, product.message);
  }
});
