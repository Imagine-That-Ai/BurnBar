import fs from 'node:fs';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import {
  createCertificationExecutionPlan,
  executeCertificationOwnershipTest
} from './parity-certification-preflight.mjs';

const RUNNER_PATH = fileURLToPath(import.meta.url);
const CONCURRENCY_VARIABLE = 'OPENBURNBAR_PARITY_COLLECTOR_CONCURRENCY';
const DEFAULT_CONCURRENCY = 4;

function executionKey(requirementId, component) {
  return `${requirementId}\0${component}`;
}

function parseConcurrency(rawValue) {
  if (rawValue === undefined) return DEFAULT_CONCURRENCY;
  if (typeof rawValue !== 'string' || !/^[1-8]$/u.test(rawValue)) {
    throw new Error(`${CONCURRENCY_VARIABLE} must be an integer between 1 and 8`);
  }
  return Number.parseInt(rawValue, 10);
}

function wellFormedResult(result, entry) {
  return typeof result === 'object' && result !== null
    && result.requirementId === entry.requirementId
    && result.component === entry.component
    && typeof result.status === 'string';
}

function runWorkerForEntry(plan, entry, active) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(RUNNER_PATH, {
      workerData: {
        repository: plan.repository,
        targetHead: plan.targetHead,
        templateRoot: plan.templateRoot,
        entry
      },
      stdout: true,
      stderr: true
    });
    active.add(worker);
    worker.stdout.resume();
    worker.stderr.pipe(process.stderr);
    const subject = `${entry.requirementId}/${entry.component}`;
    let result;
    let messageCount = 0;
    worker.on('message', (value) => {
      messageCount += 1;
      result = value;
      if (messageCount > 1) {
        reject(new Error(`ownership worker sent a duplicate result for ${subject}`));
        void worker.terminate();
      }
    });
    worker.on('error', (error) => {
      reject(new Error(`ownership worker failed for ${subject}: ${error.message}`));
    });
    worker.on('exit', (code) => {
      active.delete(worker);
      if (code !== 0) {
        reject(new Error(`ownership worker exited ${code} for ${subject}`));
      } else if (messageCount !== 1) {
        reject(new Error(`ownership worker sent ${messageCount} results for ${subject}`));
      } else if (!wellFormedResult(result, entry)) {
        reject(new Error(`ownership worker returned a malformed result for ${subject}`));
      } else {
        resolve(result);
      }
    });
  });
}

async function runBoundedPool(plan, concurrency) {
  const active = new Set();
  const results = [];
  let nextIndex = 0;
  let aborted = false;
  let firstError = null;
  const lanes = Array.from({ length: Math.min(concurrency, plan.entries.length) }, async () => {
    while (!aborted && nextIndex < plan.entries.length) {
      const index = nextIndex;
      nextIndex += 1;
      try {
        results[index] = await runWorkerForEntry(plan, plan.entries[index], active);
      } catch (error) {
        aborted = true;
        firstError ??= error;
        await Promise.allSettled([...active].map((worker) => worker.terminate()));
        return;
      }
    }
  });
  await Promise.all(lanes);
  if (firstError !== null) throw firstError;
  if (results.length !== plan.entries.length || results.some((row) => row === undefined)) {
    throw new Error('bounded ownership pool completed without a result for every entry');
  }
  return results;
}

async function main() {
  const [, , repoRoot, targetHead] = process.argv;
  if (typeof repoRoot !== 'string' || repoRoot.length === 0
      || typeof targetHead !== 'string' || targetHead.length === 0) {
    throw new Error('usage: parity-certification-ownership-runner.mjs <repoRoot> <targetHead>');
  }
  const concurrency = parseConcurrency(process.env[CONCURRENCY_VARIABLE]);
  const plan = createCertificationExecutionPlan(repoRoot, targetHead);
  let results;
  try {
    results = await runBoundedPool(plan, concurrency);
  } finally {
    fs.rmSync(plan.templateRoot, { recursive: true, force: true });
  }
  results.sort((left, right) =>
    executionKey(left.requirementId, left.component).localeCompare(
      executionKey(right.requirementId, right.component)
    )
  );
  process.stdout.write(`${JSON.stringify(results)}\n`);
}

if (isMainThread) {
  try {
    await main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }
} else {
  const { repository, targetHead, templateRoot, entry } = workerData;
  parentPort.postMessage(
    executeCertificationOwnershipTest(repository, targetHead, templateRoot, entry)
  );
}
