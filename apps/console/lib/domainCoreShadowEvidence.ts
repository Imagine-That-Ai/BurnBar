import { onAuthStateChanged } from "firebase/auth";
import { httpsCallable } from "firebase/functions";
import { auth, functions } from "./firebaseClient";
import { resolveDomainCoreEvidenceChannel } from "./domainCoreBuildProfile";
import type { CloudVaultShadowComparison } from "./domainCoreCloudVault";

const STORAGE_KEY = "openburnbar.domain-core-shadow.v2";
const MAX_SAMPLES = 800;
const BATCH_SIZE = 100;
const CORE_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/u;
const OPERATION = /^[a-z][a-z0-9_.-]{0,63}$/u;

interface ConsoleShadowSampleV2 extends CloudVaultShadowComparison {
  schemaVersion: 2;
  sampleId: string;
  channel: "internal" | "beta";
  observedAt: string;
}

let timer: ReturnType<typeof setTimeout> | undefined;
let flushing = false;
let authListenerInstalled = false;

export function recordConsoleCloudVaultShadowComparison(
  comparison: CloudVaultShadowComparison,
): void {
  if (typeof window === "undefined") return;
  const channel = resolveDomainCoreEvidenceChannel();
  if (
    !channel ||
    !CORE_VERSION.test(comparison.coreVersion) ||
    !OPERATION.test(comparison.operation) ||
    (comparison.outcome === "match") !== (comparison.mismatchCategory === null) ||
    !boundedMicros(comparison.legacyMicros) ||
    !boundedMicros(comparison.rustMicros)
  ) return;

  const samples = readSamples();
  samples.push({
    schemaVersion: 2,
    sampleId: crypto.randomUUID(),
    channel,
    observedAt: new Date().toISOString(),
    ...comparison,
  });
  writeSamples(samples.slice(-MAX_SAMPLES));
  installAuthListener();
  scheduleFlush(5_000);
}

function boundedMicros(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0 && value <= 600_000_000;
}

function readSamples(): ConsoleShadowSampleV2[] {
  try {
    const decoded: unknown = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "[]");
    return Array.isArray(decoded) ? decoded as ConsoleShadowSampleV2[] : [];
  } catch {
    localStorage.removeItem(STORAGE_KEY);
    return [];
  }
}

function writeSamples(samples: ConsoleShadowSampleV2[]): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(samples));
}

function installAuthListener(): void {
  if (authListenerInstalled) return;
  authListenerInstalled = true;
  onAuthStateChanged(auth(), (user) => {
    if (user) scheduleFlush(0);
  });
}

function scheduleFlush(delayMillis: number): void {
  if (timer !== undefined) return;
  timer = setTimeout(() => {
    timer = undefined;
    void flush();
  }, delayMillis);
}

async function flush(): Promise<void> {
  if (flushing || !auth().currentUser) return;
  flushing = true;
  try {
    while (true) {
      const samples = readSamples();
      if (samples.length === 0) return;
      const batch = samples.slice(0, BATCH_SIZE);
      const callable = httpsCallable<
        { samples: ConsoleShadowSampleV2[] },
        { accepted: number; duplicates: number }
      >(functions(), "submitDomainCoreShadowSamples");
      const response = await callable({ samples: batch });
      if (response.data.accepted + response.data.duplicates !== batch.length) {
        throw new Error("Invalid domain-core evidence acknowledgement");
      }
      const current = readSamples();
      const acknowledged = new Set(batch.map(({ sampleId }) => sampleId));
      writeSamples(current.filter(({ sampleId }) => !acknowledged.has(sampleId)));
    }
  } catch {
    scheduleFlush(30_000);
  } finally {
    flushing = false;
  }
}

export function resetConsoleShadowEvidenceForTests(): void {
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  flushing = false;
  authListenerInstalled = false;
  if (typeof localStorage !== "undefined") localStorage.removeItem(STORAGE_KEY);
}

export const flushConsoleShadowEvidenceForTests = flush;
export function pendingConsoleShadowEvidenceForTests(): unknown[] {
  return typeof localStorage === "undefined" ? [] : readSamples();
}
