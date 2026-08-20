#!/usr/bin/env node
/**
 * prime-agent-openburnbar-proxy.mjs
 *
 * Syncs OpenBurnBar's local gateway catalog into prime-agent's models.json
 * as an `openburnbar` provider so every routed BurnBar model appears inside
 * `prime-agent /model` and `prime-agent model list` as `openburnbar/<model>`.
 *
 * The provider points at the local OpenBurnBar HTTP gateway (http://127.0.0.1:8317)
 * which spends the user's stored provider credentials and records usage via
 * BurnBar's usage ledger. The same gateway already serves Claude Code, Codex,
 * Droid, Forge, and OpenCode — this adds prime-agent to that set.
 *
 * Usage:
 *   node scripts/prime-agent-openburnbar-proxy.mjs                      # sync static catalog -> models.json
 *   node scripts/prime-agent-openburnbar-proxy.mjs --live               # try live gateway /v1/models first, fall back to catalog
 *   node scripts/prime-agent-openburnbar-proxy.mjs --token <token>      # embed static auth token (or --api-key <token>)
 *   node scripts/prime-agent-openburnbar-proxy.mjs --remove             # remove openburnbar entry
 *   node scripts/prime-agent-openburnbar-proxy.mjs --status             # show current openburnbar entry
 *   node scripts/prime-agent-openburnbar-proxy.mjs --print              # print JSON fragment to stdout (no write)
 *   node scripts/prime-agent-openburnbar-proxy.mjs --gateway-host 127.0.0.1 --gateway-port 8317
 *
 * Idempotent: re-running with same catalog produces same models.json.
 * Preserves all other providers in models.json (e.g., meta).
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const DEFAULT_GATEWAY_HOST = "127.0.0.1";
const DEFAULT_GATEWAY_PORT = 8317;
const CATALOG_RELATIVE = "OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json";
const PRIME_MODELS_PATH = path.join(os.homedir(), ".prime", "agent", "models.json");

function apiKeyShellCommand() {
  // Resolves at request time; never stores secret on disk.
  // Priority: env var -> LaunchAgent plist -> Keychain fallback -> default placeholder.
  return `![ -n "$OPENBURNBAR_GATEWAY_AUTH_TOKEN" ] && echo "$OPENBURNBAR_GATEWAY_AUTH_TOKEN" || plutil -extract EnvironmentVariables.OPENBURNBAR_GATEWAY_AUTH_TOKEN raw ~/Library/LaunchAgents/com.openburnbar.daemon.plist 2>/dev/null || security find-generic-password -a $USER -s com.openburnbar.daemon.gatewayAuthToken -w 2>/dev/null || echo openburnbar-local`;
}

function contextWindowFor(providerId, modelId) {
  if (providerId === "anthropic") return 200000;
  if (providerId === "openai") return modelId.includes("5") ? 400000 : 128000;
  if (providerId === "google") return modelId.includes("pro") ? 1048576 : 128000;
  if (providerId === "meta") return 128000;
  if (providerId === "mistral") return 128000;
  if (providerId === "deepseek") return 128000;
  if (providerId === "xai") return 131072;
  if (providerId === "cohere") return 128000;
  if (providerId === "amazon") return 200000;
  if (providerId === "alibaba") return 128000;
  if (providerId === "zai") return 128000;
  if (providerId === "minimax") return 128000;
  if (providerId === "moonshot") return 128000;
  if (providerId === "opencode") return 256000;
  if (providerId === "ollama") return 128000;
  if (providerId === "mimo") return 128000;
  return 128000;
}

function reasoningFor(providerId, modelId) {
  const lower = modelId.toLowerCase();
  if (providerId === "anthropic") return true;
  if (lower.includes("reasoner") || lower.includes("thinking") || lower.includes("r1")) return true;
  if (providerId === "openai" && modelId.includes("5")) return true;
  if (providerId === "deepseek" && lower.includes("reasoner")) return true;
  return false;
}

function providerInput(providerId) {
  if (["anthropic", "openai", "google", "meta"].includes(providerId)) return ["text", "image"];
  return ["text"];
}

function loadCatalog(repoRoot) {
  const catalogPath = path.join(repoRoot, CATALOG_RELATIVE);
  // Read directly (no existsSync) so we avoid a TOCTOU race flagged by CodeQL.
  let raw;
  try {
    raw = fs.readFileSync(catalogPath, "utf8");
  } catch (err) {
    if (err?.code === "ENOENT") throw new Error(`Catalog not found at ${catalogPath}`);
    throw err;
  }
  return JSON.parse(raw);
}

function buildModelsFromCatalog(catalog) {
  const seen = new Set();
  const models = [];
  const skipProviders = new Set(["factory", "codex", "mlx", "ollama-local", "misc"]);
  for (const prov of catalog.providers ?? []) {
    const pid = prov.id;
    if (skipProviders.has(pid)) continue;
    for (const m of prov.models ?? []) {
      const rawId = m.id;
      const canonical = m.canonicalModelID;
      const modelId = canonical ? canonical : rawId.replace(/-family$/, "");
      const lower = modelId.toLowerCase();
      if (seen.has(lower)) continue;
      seen.add(lower);
      const display = m.displayName ?? modelId;
      const pricing = m.pricing ?? {};
      const cost = {
        input: pricing.inputPerMToken ?? 0,
        output: pricing.outputPerMToken ?? 0,
        cacheRead: pricing.cacheReadPerMToken ?? 0,
        cacheWrite: pricing.cacheCreationPerMToken ?? 0,
      };
      models.push({
        id: modelId,
        name: `${display} (via OpenBurnBar)`,
        reasoning: reasoningFor(pid, modelId),
        input: providerInput(pid),
        contextWindow: contextWindowFor(pid, modelId),
        maxTokens: pid === "anthropic" ? 64000 : 16384,
        cost,
      });
    }
  }
  // Stable sort by id for deterministic output
  models.sort((a, b) => a.id.localeCompare(b.id));
  return models;
}

async function fetchLiveModels(gatewayHost, gatewayPort, explicitToken) {
  const url = `http://${gatewayHost}:${gatewayPort}/v1/models`;
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), 3500);
  try {
    const headers = {};
    // Priority: explicit token -> env var -> LaunchAgent plist -> keychain
    let token = explicitToken || process.env.OPENBURNBAR_GATEWAY_AUTH_TOKEN;
    if (!token) {
      try {
        const { execSync } = await import("node:child_process");
        token = execSync(
          "plutil -extract EnvironmentVariables.OPENBURNBAR_GATEWAY_AUTH_TOKEN raw ~/Library/LaunchAgents/com.openburnbar.daemon.plist 2>/dev/null || security find-generic-password -a $USER -s com.openburnbar.daemon.gatewayAuthToken -w 2>/dev/null || echo",
          // Bounded: a hung keychain prompt must not outlive the 3.5s fetch budget.
          { encoding: "utf8", timeout: 4000 }
        ).trim();
      } catch {}
    }
    if (token) headers["authorization"] = `Bearer ${token}`;
    const res = await fetch(url, { signal: controller.signal, headers });
    if (!res.ok) return null;
    const body = await res.json();
    const data = body.data ?? body.models ?? [];
    if (!Array.isArray(data) || data.length === 0) return null;
    // Live gateway model descriptors have {id, object, owned_by}; map to prime models
    const live = [];
    for (const m of data) {
      const id = m.id ?? m.model ?? m.slug;
      if (!id || typeof id !== "string") continue;
      // Skip already namespaced openburnbar/ prefix if present
      const cleanId = id.replace(/^openburnbar\//, "");
      // Filter tiny probe/test models if needed
      live.push(cleanId);
    }
    if (live.length === 0) return null;
    // Deduplicate
    const uniq = [...new Set(live)].sort();
    return uniq;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

function buildModelsFromLiveIds(liveIds, catalog) {
  // Cross-reference live IDs with catalog for pricing/context; unknown IDs get defaults
  const catalogById = new Map();
  for (const prov of catalog.providers ?? []) {
    for (const m of prov.models ?? []) {
      const rawId = m.id;
      const canonical = m.canonicalModelID;
      const modelId = canonical ? canonical : rawId.replace(/-family$/, "");
      if (!catalogById.has(modelId.toLowerCase())) {
        catalogById.set(modelId.toLowerCase(), { provId: prov.id, entry: m, canonical: modelId });
      }
    }
  }
  const models = [];
  for (const liveId of liveIds) {
    const lower = liveId.toLowerCase();
    const found = catalogById.get(lower);
    if (found) {
      const { provId, entry, canonical } = found;
      const display = entry.displayName ?? canonical;
      const pricing = entry.pricing ?? {};
      const cost = {
        input: pricing.inputPerMToken ?? 0,
        output: pricing.outputPerMToken ?? 0,
        cacheRead: pricing.cacheReadPerMToken ?? 0,
        cacheWrite: pricing.cacheCreationPerMToken ?? 0,
      };
      models.push({
        id: canonical,
        name: `${display} (via OpenBurnBar)`,
        reasoning: reasoningFor(provId, canonical),
        input: providerInput(provId),
        contextWindow: contextWindowFor(provId, canonical),
        maxTokens: provId === "anthropic" ? 64000 : 16384,
        cost,
      });
    } else {
      // Unknown live model - expose with generic defaults so new gateway models appear immediately
      models.push({
        id: liveId,
        name: `${liveId} (via OpenBurnBar)`,
        reasoning: lower.includes("thinking") || lower.includes("reasoner"),
        input: ["text"],
        contextWindow: 128000,
        maxTokens: 16384,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      });
    }
  }
  models.sort((a, b) => a.id.localeCompare(b.id));
  return models;
}

function readModelsJson(modelsPath) {
  // Read directly (no existsSync) so we avoid a TOCTOU race flagged by CodeQL.
  let raw;
  try {
    raw = fs.readFileSync(modelsPath, "utf8").trim();
  } catch (err) {
    if (err?.code === "ENOENT") return { providers: {} };
    throw err;
  }
  if (!raw) return { providers: {} };
  const parsed = JSON.parse(raw);
  if (!parsed.providers || typeof parsed.providers !== "object") parsed.providers = {};
  return parsed;
}

/**
 * Placeholder shown in preview output instead of a user-supplied static token.
 * The literal token is argv-derived taint; printing it is the exact clear-text
 * credential sink CodeQL blocked in #2192. The marker proves `--print`/
 * `--status` inspected the right field without ever echoing the secret.
 */
const REDACTED_API_KEY_MARKER = "<redacted: static gateway token>";

/**
 * Strip credential material from any console/JSON output.
 * Do not log apiKey or any value derived from it — CodeQL taints those sinks.
 */
function redactProviderForDisplay(entry) {
  if (!entry || typeof entry !== "object") return entry;
  const { apiKey: _apiKey, ...rest } = entry;
  return rest;
}

function writeModelsJson(modelsPath, data) {
  const dir = path.dirname(modelsPath);
  fs.mkdirSync(dir, { recursive: true });
  const payload = `${JSON.stringify(data, null, 2)}\n`;
  // Atomic replace: no existsSync check before write (CodeQL js/file-system-race).
  const tmpPath = `${modelsPath}.${process.pid}.tmp`;
  fs.writeFileSync(tmpPath, payload, "utf8");
  try {
    try {
      fs.copyFileSync(modelsPath, `${modelsPath}.bak`);
    } catch (err) {
      if (err?.code !== "ENOENT") {
        // Best-effort backup only.
      }
    }
    fs.renameSync(tmpPath, modelsPath);
  } catch (err) {
    try { fs.unlinkSync(tmpPath); } catch { /* ignore */ }
    throw err;
  }
}

async function main() {
  const args = process.argv.slice(2);
  const opts = {
    live: args.includes("--live"),
    remove: args.includes("--remove"),
    status: args.includes("--status"),
    print: args.includes("--print"),
    help: args.includes("--help") || args.includes("-h"),
    gatewayHost: DEFAULT_GATEWAY_HOST,
    gatewayPort: DEFAULT_GATEWAY_PORT,
    token: undefined,
  };
  // Both `--flag value` and `--flag=value` spellings are accepted.
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--gateway-host" && args[i+1]) opts.gatewayHost = args[++i];
    else if (args[i].startsWith("--gateway-host=")) opts.gatewayHost = args[i].slice("--gateway-host=".length);
    else if (args[i] === "--gateway-port" && args[i+1]) opts.gatewayPort = parseInt(args[++i], 10);
    else if (args[i].startsWith("--gateway-port=")) opts.gatewayPort = parseInt(args[i].slice("--gateway-port=".length), 10);
    else if ((args[i] === "--token" || args[i] === "--api-key") && args[i+1]) opts.token = args[++i];
    else if (args[i].startsWith("--token=")) opts.token = args[i].slice("--token=".length);
    else if (args[i].startsWith("--api-key=")) opts.token = args[i].slice("--api-key=".length);
  }
  opts.token = opts.token?.trim() || undefined;
  if (opts.help) {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(0,30).join("\n"));
    console.log("\nOptions: --live --remove --status --print --token <token> --api-key <token> --gateway-host <host> --gateway-port <port>");
    process.exit(0);
  }
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const modelsPath = process.env.PRIME_MODELS_PATH ?? PRIME_MODELS_PATH;

  if (opts.status) {
    const data = readModelsJson(modelsPath);
    const entry = data.providers?.["openburnbar"];
    if (!entry) {
      console.log("openburnbar provider: not configured");
      console.log(`models.json: ${modelsPath}`);
      console.log(`gateway: http://${opts.gatewayHost}:${opts.gatewayPort}`);
      process.exit(1);
    }
    const safe = redactProviderForDisplay(entry);
    console.log(`openburnbar provider: configured`);
    console.log(`  baseUrl: ${safe.baseUrl}`);
    console.log(`  api: ${safe.api}`);
    console.log(`  models: ${safe.models?.length ?? 0}`);
    console.log(`  first: ${safe.models?.[0]?.id ?? "-"}`);
    console.log(`  path: ${modelsPath}`);
    process.exit(0);
  }

  if (opts.remove) {
    const data = readModelsJson(modelsPath);
    if (data.providers["openburnbar"]) {
      delete data.providers["openburnbar"];
      if (!opts.print) writeModelsJson(modelsPath, data);
      console.log(`Removed openburnbar provider from ${modelsPath}`);
    } else {
      console.log("openburnbar provider not present — nothing to remove.");
    }
    if (opts.print) console.log(JSON.stringify({ providers: {} }, null, 2));
    process.exit(0);
  }

  const catalog = loadCatalog(repoRoot);
  let models;
  let source = "catalog";
  if (opts.live) {
    const liveIds = await fetchLiveModels(opts.gatewayHost, opts.gatewayPort, opts.token);
    if (liveIds && liveIds.length > 0) {
      models = buildModelsFromLiveIds(liveIds, catalog);
      source = `live gateway http://${opts.gatewayHost}:${opts.gatewayPort}/v1/models (${liveIds.length} models)`;
    } else {
      console.warn(`Live gateway not reachable at http://${opts.gatewayHost}:${opts.gatewayPort}/v1/models — falling back to static catalog.`);
      models = buildModelsFromCatalog(catalog);
    }
  } else {
    models = buildModelsFromCatalog(catalog);
  }

  const providerEntry = {
    name: "OpenBurnBar Gateway",
    baseUrl: `http://${opts.gatewayHost}:${opts.gatewayPort}/v1`,
    api: "openai-completions",
    apiKey: opts.token ?? apiKeyShellCommand(),
    models,
  };

  if (opts.print) {
    // --print is the preview surface: it must show what models.json will hold.
    // The default apiKey is the env→plist→keychain shell resolver (no secret in
    // the string), so it prints verbatim; a --token literal is redacted in place
    // instead, because it is user-typed credential material.
    const printable = {
      ...providerEntry,
      apiKey: opts.token ? REDACTED_API_KEY_MARKER : providerEntry.apiKey,
    };
    console.log(JSON.stringify({ providers: { openburnbar: printable } }, null, 2));
    process.exit(0);
  }

  const data = readModelsJson(modelsPath);
  const existingCount = data.providers["openburnbar"]?.models?.length ?? 0;
  data.providers["openburnbar"] = providerEntry;
  writeModelsJson(modelsPath, data);
  console.log(`Synced openburnbar provider -> ${modelsPath}`);
  console.log(`  source: ${source}`);
  console.log(`  models: ${models.length} (was ${existingCount})`);
  console.log(`  gateway: http://${opts.gatewayHost}:${opts.gatewayPort}`);
  console.log(`  apiKey: ${opts.token ? "static token (passed via CLI)" : "shell command (resolves at request time from env/LaunchAgent/keychain)"}`);
  console.log(`\nVerify: prime-agent model list openburnbar | head`);
  console.log(`Try:     prime-agent --provider openburnbar --model ${models[0]?.id ?? "claude-sonnet-4-6"} -p "hello via burnbar"`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
