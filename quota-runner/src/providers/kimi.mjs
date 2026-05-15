import { valueBucket, percentBucket } from "./shared.mjs";

const KIMI_ENDPOINTS = [
  { label: "Kimi (International)", base: "https://api.kimi.ai" },
  { label: "Moonshot (China)", base: "https://api.moonshot.cn" },
];

const MODELS_TIMEOUT_MS = 15_000;
const BALANCE_TIMEOUT_MS = 10_000;

export async function fetchKimiQuota({ credential, accountID }) {
  if (!credential.trim()) {
    throw new Error(
      "Kimi quota requires an API key credential; provide the KIMI_API_KEY or MOONSHOT_API_KEY as the credential field."
    );
  }

  const sourceId = credential.trim() ? "hosted-runner" : "self-hosted-runner";

  // Find the first reachable endpoint
  let activeBase = null;
  let activeLabel = null;
  let models = null;
  for (const { label, base } of KIMI_ENDPOINTS) {
    const result = await fetchModels(base, credential);
    if (result.ok) {
      activeBase = base;
      activeLabel = label;
      models = result.models;
      break;
    }
  }

  if (!activeBase) {
    throw new Error(
      "Could not authenticate with any Kimi/Moonshot endpoint; verify the API key is valid."
    );
  }

  // Attempt balance endpoint
  let balance = null;
  let balanceError = null;
  try {
    balance = await fetchBalance(activeBase, credential);
  } catch (err) {
    balanceError = err;
  }

  const buckets = buildBuckets(models, balance);
  const hasBalance = balance != null;
  const confidence = hasBalance ? "high" : "medium";
  const statusMessage = hasBalance
    ? `Kimi quota fetched from ${activeLabel} balance API for ${accountID}.`
    : `Kimi credential validated against ${activeLabel}; balance endpoint unavailable — reporting usage-only buckets for ${accountID}.`;

  return {
    provider: "kimi",
    sourceKind: "provider",
    sourceId,
    fetchedAt: new Date().toISOString(),
    source: "Kimi API",
    confidence,
    managementURL: "https://platform.moonshot.cn/console/api-keys",
    statusMessage,
    buckets,
  };
}

async function fetchModels(base, apiKey) {
  const url = `${base}/v1/models`;
  try {
    const res = await timedFetch(url, {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(MODELS_TIMEOUT_MS),
    });
    if (!res.ok) return { ok: false };
    const body = await res.json();
    const models = Array.isArray(body?.data) ? body.data : [];
    return { ok: true, models };
  } catch {
    return { ok: false };
  }
}

async function fetchBalance(base, apiKey) {
  const url = `${base}/v1/users/me/balance`;
  const res = await timedFetch(url, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(BALANCE_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`balance endpoint returned ${res.status}`);
  }
  const body = await res.json();
  return body?.data ?? body;
}

function buildBuckets(models, balance) {
  const buckets = [];

  // Model access bucket — what models are available to this key
  if (models.length > 0) {
    buckets.push(valueBucket({
      name: "Kimi available models",
      used: models.length,
      limit: models.length,
      window: "static",
      source: "kimi-models",
      unit: "models",
    }));
  }

  // Balance buckets if available
  if (balance != null) {
    const available = finiteNumber(balance.available_balance ?? balance.availableBalance ?? balance.balance, null);
    const used = finiteNumber(balance.used_balance ?? balance.usedBalance ?? balance.used, null);
    const total = finiteNumber(balance.total_balance ?? balance.totalBalance ?? balance.total, null);

    if (available != null && total != null) {
      const usedAmount = used != null ? used : Math.max(0, total - available);
      buckets.push(valueBucket({
        name: "Kimi account balance",
        used: usedAmount,
        limit: total,
        remaining: available,
        window: "monthly",
        source: "kimi-balance",
        unit: "credits",
      }));
    } else if (available != null) {
      buckets.push(valueBucket({
        name: "Kimi remaining balance",
        used: 0,
        limit: available,
        remaining: available,
        window: "monthly",
        source: "kimi-balance",
        unit: "credits",
      }));
    }
  }

  return buckets;
}

function finiteNumber(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

async function timedFetch(url, options) {
  // Node 18+ supports AbortSignal.timeout; wrap for cleaner errors on timeout
  const res = await globalThis.fetch(url, options);
  return res;
}
