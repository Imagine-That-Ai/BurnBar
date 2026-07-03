export type PerfSample = { name: string; ms: number; at: string; source: string };

const samples: PerfSample[] = [];

export type PerfMarkEnd = () => void;

async function persistSample(sample: PerfSample): Promise<void> {
  if (typeof window === 'undefined' || !('__TAURI_INTERNALS__' in window)) return;
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('record_perf_sample', { sample });
  } catch {
    // Perf persistence is evidence-only; the in-memory support table still reflects the sample.
  }
}

export function recordPerfSample(name: string, ms: number, source: string): void {
  const sample = { name, ms, at: new Date().toISOString(), source };
  samples.push(sample);
  void persistSample(sample);
}

export function markStart(name: string, source = 'linux-shell-render'): PerfMarkEnd {
  const t0 = performance.now();
  return () => {
    const ms = performance.now() - t0;
    recordPerfSample(name, ms, source);
  };
}

export function listPerfSamples(): PerfSample[] {
  return [...samples];
}

export function clearPerfSamples(): void {
  samples.length = 0;
}
