#!/usr/bin/env node
/**
 * OpenBurnBar Functions Performance Profiler
 *
 * Profiles the Cloud Functions build + startup using Node.js built-in
 * performance hooks and generates a CPU profile for analysis in Chrome DevTools.
 *
 * Usage:
 *   # Profile the functions build:
 *   node scripts/profile-functions.mjs
 *
 *   # View the profile:
 *   Open Chrome DevTools → Performance → Load profile → functions-profile-*.cpuprofile
 *
 *   # Run with heap snapshot (for memory leaks):
 *   PROFILE_HEAP=true node scripts/profile-functions.mjs
 *
 * Output: functions-profile-<timestamp>.cpuprofile
 *         functions-heap-<timestamp>.heapsnapshot (if PROFILE_HEAP=true)
 */

import { Session } from 'node:inspector/promises';
import { writeFileSync } from 'node:fs';
import { performance, PerformanceObserver } from 'node:perf_hooks';
import { execSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const PROFILE_HEAP = process.env.PROFILE_HEAP === 'true';

async function profileFunctions() {
  console.log('OpenBurnBar Functions Performance Profiler');
  console.log('==========================================');

  const session = new Session();
  session.connect();

  // ── CPU profiling ──────────────────────────────────────────────────────────
  console.log('\n[1/4] Starting CPU profiler...');
  await session.post('Profiler.enable');
  await session.post('Profiler.start');

  const profileStart = performance.now();

  // ── Measure TypeScript compilation ────────────────────────────────────────
  console.log('[2/4] Measuring TypeScript compilation...');
  const tscStart = performance.now();
  try {
    execSync('npx tsc --noEmit', { cwd: ROOT, stdio: 'pipe' });
    const tscDuration = performance.now() - tscStart;
    console.log(`     tsc --noEmit: ${tscDuration.toFixed(0)}ms`);
  } catch (err) {
    console.warn('     tsc failed (type errors detected)');
  }

  // ── Measure ESLint ────────────────────────────────────────────────────────
  console.log('[3/4] Measuring ESLint...');
  const lintStart = performance.now();
  try {
    execSync('npx eslint src --ext .ts --quiet', { cwd: ROOT, stdio: 'pipe' });
    const lintDuration = performance.now() - lintStart;
    console.log(`     ESLint: ${lintDuration.toFixed(0)}ms`);
  } catch {
    const lintDuration = performance.now() - lintStart;
    console.log(`     ESLint (with warnings): ${lintDuration.toFixed(0)}ms`);
  }

  // ── Stop CPU profiler and save ─────────────────────────────────────────────
  console.log('[4/4] Saving profiles...');
  const { profile } = await session.post('Profiler.stop');
  const totalDuration = performance.now() - profileStart;

  const cpuProfilePath = path.join(ROOT, `functions-profile-${Date.now()}.cpuprofile`);
  writeFileSync(cpuProfilePath, JSON.stringify(profile));
  console.log(`\n✓ CPU profile saved: ${cpuProfilePath}`);
  console.log(`  Total profiled duration: ${totalDuration.toFixed(0)}ms`);

  // ── Heap snapshot (optional) ───────────────────────────────────────────────
  if (PROFILE_HEAP) {
    console.log('\nCapturing heap snapshot...');
    await session.post('HeapProfiler.enable');
    const { profile: heapProfile } = await session.post('HeapProfiler.takeHeapSnapshot', {
      reportProgress: false,
    });
    const heapPath = path.join(ROOT, `functions-heap-${Date.now()}.heapsnapshot`);
    writeFileSync(heapPath, JSON.stringify(heapProfile));
    console.log(`✓ Heap snapshot saved: ${heapPath}`);
  }

  session.disconnect();

  console.log('\n── How to analyze ───────────────────────────────────────────');
  console.log('1. Open Chrome DevTools (F12)');
  console.log('2. Go to Performance tab → ⊕ Load profile');
  console.log(`3. Select: ${cpuProfilePath}`);
  console.log('4. Look for hot functions in the flame chart');
  console.log('─────────────────────────────────────────────────────────────\n');
}

// ── Performance Observer for long tasks ─────────────────────────────────────
const obs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    if (entry.duration > 100) {
      console.warn(`  ⚠ Long task: ${entry.name} took ${entry.duration.toFixed(0)}ms`);
    }
  }
});
obs.observe({ entryTypes: ['measure', 'function'] });

profileFunctions().catch((err) => {
  console.error('Profiling failed:', err);
  process.exit(1);
});
