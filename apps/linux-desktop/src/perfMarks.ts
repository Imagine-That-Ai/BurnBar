export type PerfSample = { name: string; ms: number; at: string };

const samples: PerfSample[] = [];

export type PerfMarkEnd = () => void;

export function markStart(name: string): PerfMarkEnd {
  const t0 = performance.now();
  return () => {
    const ms = performance.now() - t0;
    samples.push({ name, ms, at: new Date().toISOString() });
  };
}

export function listPerfSamples(): PerfSample[] {
  return [...samples];
}

export function clearPerfSamples(): void {
  samples.length = 0;
}