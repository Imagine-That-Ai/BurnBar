/**
 * @fileoverview Pure counter -> summary aggregation for usage rollups.
 *
 * Extracted from rollupCompute.ts (wave 4): these functions fold counter
 * bucket documents into typed summary arrays with no I/O, no clock, and no
 * Firestore access, so they unit-test without fixtures.
 */

import type { DocumentData } from "firebase-admin/firestore";
import type {
  ComboSummary,
  DeviceSummary,
  ExecutionSourceSummary,
  ModelSummary,
  ProviderAccountSummary,
  ProviderSummary,
} from "@openburnbar/functions-shared/types.js";
import { isProviderAccountStorageScope, parseProvider } from "@openburnbar/functions-shared/guards.js";

export function sumNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function aggregateProviderSummaries(providers: DocumentData[]): ProviderSummary[] {
  const providerMap = new Map<string, ProviderSummary>();
  for (const doc of providers) {
    const providerName = typeof doc.provider === "string" ? doc.provider : "unknown";
    const provider = parseProvider(providerName);
    if (!provider) continue;
    const existing = providerMap.get(provider);
    if (existing) {
      existing.totalRequests += sumNumber(doc.requests);
      existing.totalTokens += sumNumber(doc.tokens);
      existing.totalCost = (existing.totalCost ?? 0) + sumNumber(doc.costUsd);
    } else {
      providerMap.set(provider, {
        provider,
        providerID: typeof doc.providerID === "string" ? doc.providerID : undefined,
        totalRequests: sumNumber(doc.requests),
        totalTokens: sumNumber(doc.tokens),
        totalCost: sumNumber(doc.costUsd),
      });
    }
  }
  return Array.from(providerMap.values()).filter(
    (entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0,
  );
}

export function aggregateAccountSummaries(accounts: DocumentData[]): ProviderAccountSummary[] {
  const accountMap = new Map<string, ProviderAccountSummary>();
  for (const doc of accounts) {
    const providerIDRaw = typeof doc.providerID === "string" ? doc.providerID : "unknown";
    const providerID = parseProvider(providerIDRaw) ?? providerIDRaw;
    const id = typeof doc.accountID === "string" ? doc.accountID : `${providerID}:unattributed`;
    const storageScopeRaw = doc.storageScope;
    const storageScope =
      typeof storageScopeRaw === "string" && isProviderAccountStorageScope(storageScopeRaw)
        ? storageScopeRaw
        : undefined;
    const existing = accountMap.get(id);
    if (existing) {
      existing.totalRequests += sumNumber(doc.requests);
      existing.totalTokens += sumNumber(doc.tokens);
      existing.totalCost = (existing.totalCost ?? 0) + sumNumber(doc.costUsd);
    } else {
      accountMap.set(id, {
        id,
        providerID,
        accountID: typeof doc.accountID === "string" ? doc.accountID : undefined,
        accountLabel: typeof doc.accountLabel === "string" ? doc.accountLabel : "Usage not linked to an account yet",
        storageScope,
        totalRequests: sumNumber(doc.requests),
        totalTokens: sumNumber(doc.tokens),
        totalCost: sumNumber(doc.costUsd),
      });
    }
  }
  return Array.from(accountMap.values()).filter(
    (entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0,
  );
}

export function aggregateModelSummaries(models: DocumentData[]): ModelSummary[] {
  const modelMap = new Map<string, ModelSummary>();
  for (const doc of models) {
    const providerName = typeof doc.provider === "string" ? doc.provider : "unknown";
    const provider = parseProvider(providerName);
    if (!provider) continue;
    const model = typeof doc.model === "string" ? doc.model : "";
    if (!model) continue;
    const id = `${provider}:${model}`;
    const existing = modelMap.get(id);
    if (existing) {
      existing.requests += sumNumber(doc.requests);
      existing.tokens += sumNumber(doc.tokens);
      existing.cost = (existing.cost ?? 0) + sumNumber(doc.costUsd);
    } else {
      modelMap.set(id, {
        provider,
        model,
        requests: sumNumber(doc.requests),
        tokens: sumNumber(doc.tokens),
        cost: sumNumber(doc.costUsd),
      });
    }
  }
  return Array.from(modelMap.values()).filter(
    (entry) => entry.requests !== 0 || entry.tokens !== 0 || (entry.cost ?? 0) !== 0,
  );
}

export function aggregateDeviceSummaries(devices: DocumentData[]): DeviceSummary[] {
  const deviceMap = new Map<string, DeviceSummary>();
  for (const doc of devices) {
    const deviceId = typeof doc.deviceId === "string" ? doc.deviceId : "";
    if (!deviceId) continue;
    const existing = deviceMap.get(deviceId);
    if (existing) {
      existing.requests += sumNumber(doc.requests);
      existing.tokens += sumNumber(doc.tokens);
    } else {
      deviceMap.set(deviceId, {
        deviceId,
        requests: sumNumber(doc.requests),
        tokens: sumNumber(doc.tokens),
      });
    }
  }
  return Array.from(deviceMap.values()).filter((entry) => entry.requests !== 0 || entry.tokens !== 0);
}

export function aggregateExecutionSourceSummaries(executionSources: DocumentData[]): ExecutionSourceSummary[] {
  const sourceMap = new Map<string, ExecutionSourceSummary>();
  for (const doc of executionSources) {
    const sourceId = typeof doc.executionSourceId === "string" ? doc.executionSourceId : "";
    if (!sourceId) continue;
    const sourceName = typeof doc.executionSourceName === "string" ? doc.executionSourceName : "";
    const existing = sourceMap.get(sourceId);
    if (existing) {
      if (!existing.sourceName && sourceName) existing.sourceName = sourceName;
      existing.totalRequests += sumNumber(doc.requests);
      existing.totalTokens += sumNumber(doc.tokens);
      existing.totalCost += sumNumber(doc.costUsd);
    } else {
      sourceMap.set(sourceId, {
        sourceId,
        sourceName,
        totalRequests: sumNumber(doc.requests),
        totalTokens: sumNumber(doc.tokens),
        totalCost: sumNumber(doc.costUsd),
      });
    }
  }
  return Array.from(sourceMap.values())
    .filter((entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || entry.totalCost !== 0)
    .sort((a, b) => b.totalTokens - a.totalTokens || b.totalRequests - a.totalRequests);
}

export function aggregateComboSummaries(combos: DocumentData[]): ComboSummary[] {
  const comboMap = new Map<string, ComboSummary>();
  for (const doc of combos) {
    const sourceId = typeof doc.executionSourceId === "string" ? doc.executionSourceId : "";
    if (!sourceId) continue;
    const providerName = typeof doc.provider === "string" ? doc.provider : "unknown";
    const provider = parseProvider(providerName);
    if (!provider) continue;
    const model = typeof doc.model === "string" ? doc.model : "";
    if (!model) continue;
    const sourceName = typeof doc.executionSourceName === "string" ? doc.executionSourceName : "";
    const id = `${sourceId}:${provider}:${model}`;
    const existing = comboMap.get(id);
    if (existing) {
      if (!existing.sourceName && sourceName) existing.sourceName = sourceName;
      existing.requests += sumNumber(doc.requests);
      existing.tokens += sumNumber(doc.tokens);
      existing.cost += sumNumber(doc.costUsd);
    } else {
      comboMap.set(id, {
        sourceId,
        sourceName,
        provider,
        model,
        requests: sumNumber(doc.requests),
        tokens: sumNumber(doc.tokens),
        cost: sumNumber(doc.costUsd),
      });
    }
  }
  return Array.from(comboMap.values())
    .filter((entry) => entry.requests !== 0 || entry.tokens !== 0 || entry.cost !== 0)
    .sort((a, b) => b.tokens - a.tokens || b.requests - a.requests);
}
