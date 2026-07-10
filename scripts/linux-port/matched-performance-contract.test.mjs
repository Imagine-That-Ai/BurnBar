import assert from 'node:assert/strict';
import test from 'node:test';
import {
  compareMatchedPerformance,
  dockerHostIdentityArguments
} from './lib/matched-performance.mjs';

const ids = [
  'sqlite.range-query',
  'sqlite.fts-memory-search',
  'jsonl.incremental-decode',
  'stream.first-visible-delta-decode'
];
const profile = { rows: 100, samples: 5, warmups: 1, soakSeconds: 1, seed: 20260709 };
const budget = {
  matched: {
    protocolVersion: 'openburnbar-matched-workload-v1',
    expectedWorkloads: ids,
    profiles: { smoke: profile },
    workloadThresholdsMs: Object.fromEntries(ids.map((id) => [id, { p95: 50, p99: 80 }])),
    linuxParity: { p95Multiplier: 3, p95AdditiveFloorMs: 5, p99Multiplier: 4, p99AdditiveFloorMs: 10 },
    resourceThresholds: { maximumRssBytes: 1_000_000_000, maximumRssGrowthBytes: 100_000_000, maximumCpuUtilizationPercent: 150 }
  }
};

function report(platform) {
  return {
    schemaVersion: 1,
    protocolVersion: 'openburnbar-matched-workload-v1',
    host: { platform, architecture: platform === 'macos' ? 'arm64' : 'aarch64' },
    configuration: { ...profile },
    workloads: ids.map((id, index) => ({
      id,
      unit: 'milliseconds',
      sampleCount: 5,
      checksum: 1000 + index,
      percentiles: { minimum: 1, p50: 2, p95: 3, p99: 4, maximum: 5 }
    })),
    soak: {
      requestedSeconds: 1,
      elapsedSeconds: 1.01,
      iterations: 10,
      samples: [{}, {}],
      rssStartBytes: 10_000_000,
      rssEndBytes: 11_000_000,
      rssMaximumBytes: 12_000_000,
      rssGrowthBytes: 1_000_000,
      cpuUtilizationPercent: 99
    },
    pass: true
  };
}

function compare(mutator = () => {}) {
  const macos = report('macos');
  const linux = report('linux');
  mutator({ macos, linux });
  return compareMatchedPerformance({ macos, linux, budget, profile: 'smoke' });
}

test('Linux Docker probes retain host ownership of bind-mounted evidence', () => {
  assert.deepEqual(
    dockerHostIdentityArguments(1001, 121),
    ['--user', '1001:121', '-e', 'HOME=/tmp/openburnbar-home']
  );
  assert.deepEqual(dockerHostIdentityArguments(undefined, undefined), []);
  assert.deepEqual(dockerHostIdentityArguments(-1, 121), []);
});

test('matching reports pass with architecture aliases', () => {
  const result = compare();
  assert.equal(result.pass, true);
  assert.equal(result.workloads.length, 4);
});

test('missing, duplicate, unexpected, or checksum-mutated workloads fail', () => {
  const mutations = [
    ({ linux }) => linux.workloads.pop(),
    ({ linux }) => linux.workloads.push(structuredClone(linux.workloads[0])),
    ({ linux }) => { linux.workloads[0].id = 'unexpected'; },
    ({ linux }) => { linux.workloads[0].checksum += 1; }
  ];
  for (const mutate of mutations) assert.equal(compare(mutate).pass, false);
});

test('configuration, platform, architecture, and internal probe drift fail', () => {
  const mutations = [
    ({ linux }) => { linux.configuration.seed += 1; },
    ({ linux }) => { linux.host.platform = 'macos'; },
    ({ linux }) => { linux.host.architecture = 'x86_64'; },
    ({ linux }) => { linux.pass = false; }
  ];
  for (const mutate of mutations) assert.equal(compare(mutate).pass, false);
});

test('malformed or regressed tail latency fails closed', () => {
  const malformed = compare(({ linux }) => { linux.workloads[0].percentiles.p95 = 0.5; });
  assert.equal(malformed.pass, false);
  const absolute = compare(({ linux }) => {
    linux.workloads[0].percentiles = { minimum: 1, p50: 2, p95: 60, p99: 70, maximum: 80 };
  });
  assert.equal(absolute.pass, false);
  const parity = compare(({ linux }) => {
    linux.workloads[0].percentiles = { minimum: 1, p50: 2, p95: 10, p99: 17, maximum: 18 };
  });
  assert.equal(parity.pass, false);
});

test('short soak, inconsistent RSS, memory growth, and CPU regressions fail', () => {
  const mutations = [
    ({ linux }) => { linux.soak.elapsedSeconds = 0.5; },
    ({ linux }) => { linux.soak.rssGrowthBytes = 0; },
    ({ linux }) => { linux.soak.rssEndBytes = 200_000_000; linux.soak.rssGrowthBytes = 190_000_000; linux.soak.rssMaximumBytes = 200_000_000; },
    ({ linux }) => { linux.soak.cpuUtilizationPercent = 151; }
  ];
  for (const mutate of mutations) assert.equal(compare(mutate).pass, false);
});
