import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import test from 'node:test';
import {
  attachMatchedPerformanceProvenance,
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
  const value = {
    schemaVersion: 1,
    protocolVersion: 'openburnbar-matched-workload-v1',
    generatedAt: '2026-07-20T12:00:01.000Z',
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
    pass: true,
    provenance: {
      schemaVersion: 1, producer: 'openburnbar-matched-performance-v2', platform, profile: 'smoke',
      gitCommit: '1'.repeat(40), packageVersion: '1.2.3', sourceDigest: '2'.repeat(64),
      candidate: { runId: null, artifactDigest: null },
      startedAt: '2026-07-20T12:00:00.000Z', endedAt: '2026-07-20T12:00:02.000Z', payloadSha256: ''
    }
  };
  const payload = structuredClone(value);
  delete payload.provenance;
  value.provenance.payloadSha256 = crypto.createHash('sha256').update(JSON.stringify(payload)).digest('hex');
  return value;
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

test('producer attaches candidate, source, timing, and payload provenance', () => {
  const bare = report('linux');
  delete bare.provenance;
  const stamped = attachMatchedPerformanceProvenance(bare, {
    platform: 'linux', profile: 'smoke', gitCommit: '1'.repeat(40), packageVersion: '1.2.3',
    sourceDigest: '2'.repeat(64), candidateRunId: '42',
    candidateArtifactDigest: `sha256:${'3'.repeat(64)}`,
    startedAt: '2026-07-20T12:00:00.000Z', endedAt: '2026-07-20T12:00:02.000Z'
  });
  assert.equal(stamped.provenance.candidate.runId, '42');
  assert.match(stamped.provenance.payloadSha256, /^[a-f0-9]{64}$/u);
  const macos = report('macos');
  macos.provenance.candidate = structuredClone(stamped.provenance.candidate);
  macos.provenance.payloadSha256 = (() => {
    const payload = structuredClone(macos);
    delete payload.provenance;
    return crypto.createHash('sha256').update(JSON.stringify(payload)).digest('hex');
  })();
  const result = compareMatchedPerformance({
    macos,
    linux: stamped,
    budget,
    profile: 'smoke',
    expectedProvenance: {
      gitCommit: '1'.repeat(40), packageVersion: '1.2.3', sourceDigest: '2'.repeat(64),
      candidateRunId: '42', candidateArtifactDigest: `sha256:${'3'.repeat(64)}`
    }
  });
  assert.equal(result.pass, true, result.errors.join('; '));
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

test('missing, relabeled, stale, or payload-detached provenance fails', () => {
  const mutations = [
    ({ linux }) => { delete linux.provenance; },
    ({ linux }) => { linux.provenance.gitCommit = '3'.repeat(40); },
    ({ linux }) => { linux.provenance.endedAt = 'invalid'; },
    ({ linux }) => { linux.workloads[0].checksum += 1; }
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
