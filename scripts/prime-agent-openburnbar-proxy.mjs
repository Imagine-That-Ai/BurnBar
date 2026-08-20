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
 * Auth: the emitted apiKey is a shell command prime-agent runs per request,
 * resolving $OPENBURNBAR_GATEWAY_AUTH_TOKEN -> the daemon LaunchAgent plist ->
 * the openburnbar-local placeholder. Every rung is non-interactive, so SSH, CI,
 * and background agents get the same token a GUI session does. Export the env
 * var on hosts without the daemon plist; prefer that over --token, which writes
 * the literal to disk. `--print` never prints a --token literal.
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

/**
 * Shell command prime-agent runs to resolve the gateway bearer token at request
 * time, so models.json never holds a secret. Rungs: `$OPENBURNBAR_GATEWAY_AUTH_TOKEN`
 * -> the daemon LaunchAgent plist -> the `openburnbar-local` placeholder. Every
 * rung is non-interactive, which is the point: SSH sessions, CI runners, and
 * background agents resolve the same token a GUI session does.
 *
 * There is deliberately no `security find-generic-password` rung. The app stores
 * the token under service `com.openburnbar.chat-gateway-secrets` / account
 * `settings.gateway.http.authToken` with an app-scoped ACL, so reading it from a
 * foreign binary either blocks on a GUI authorization prompt or fails with
 * errSecInteractionNotAllowed. The plist carries the same token by construction —
 * OpenBurnBarDaemonManager writes it into EnvironmentVariables whenever gateway
 * auth is enabled, which is the fail-closed default.
 *
 * `printf '%s\n'` rather than `echo`: POSIX `echo` expands backslash escapes, so
 * `echo` silently corrupts any token containing one.
 */
const PLIST_TOKEN_COMMAND =
  "plutil -extract EnvironmentVariables.OPENBURNBAR_GATEWAY_AUTH_TOKEN raw " +
  "~/Library/LaunchAgents/com.openburnbar.daemon.plist 2>/dev/null";

function apiKeyShellCommand() {
  // Leading `!` is prime-agent's "run this as a shell command" marker (see
  // resolveConfigValue); it is stripped before exec, not shell negation.
  return `![ -n "$OPENBURNBAR_GATEWAY_AUTH_TOKEN" ] && printf '%s\\n' "$OPENBURNBAR_GATEWAY_AUTH_TOKEN" || ${PLIST_TOKEN_COMMAND} || printf '%s\\n' openburnbar-local`;
}

/**
 * Single source of truth for the gateway URL, and the validation gate for
 * `--gateway-host` / `--gateway-port`. `new URL` rejects every malformed
 * combination — empty host, non-numeric or out-of-range port, a pasted
 * `http://host` — that would otherwise be concatenated straight into
 * models.json and resurface later as an opaque request failure. IPv6 literals
 * need brackets before they parse.
 */
function gatewayBaseUrl(host, port) {
  const raw = String(host);
  const literal = raw.includes(":") && !raw.startsWith("[") ? `[${raw}]` : raw;
  const numericPort = Number(String(port).trim());
  // `new URL` accepts port 0 by normalising it away to the scheme default, and
  // 0 is not a port a client can connect to, so the range is checked here
  // rather than left to the parser.
  const inRange = Number.isInteger(numericPort) && numericPort >= 1 && numericPort <= 65535;
  if (inRange) {
    try {
      return new URL(`http://${literal}:${numericPort}/v1`).href;
    } catch { /* fall through to the shared diagnostic */ }
  }
  throw new Error(
    `Invalid gateway address: --gateway-host "${host}" --gateway-port "${port}". ` +
    "Expected a bare host or IP and a port from 1 to 65535.",
  );
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

async function fetchLiveModels(gatewayBase, explicitToken) {
  const url = `${gatewayBase}/models`;
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), 3500);
  try {
    const headers = {};
    // Same rungs as apiKeyShellCommand(), plus the explicit flag ahead of them.
    let token = explicitToken || process.env.OPENBURNBAR_GATEWAY_AUTH_TOKEN;
    if (!token) {
      try {
        const { execSync } = await import("node:child_process");
        token = execSync(
          `${PLIST_TOKEN_COMMAND} || true`,
          // Bounded so a slow plist read cannot outlive the 3.5s fetch budget.
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
    throw new Error(`Cannot read ${modelsPath}: ${err.message}`);
  }
  if (!raw) return { providers: {} };
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(
      `${modelsPath} is not valid JSON: ${err.message}. ` +
      "Move it aside and re-run — prime-agent recreates it on demand.",
    );
  }
  // A non-object root, or a `providers` array, loses the merge silently:
  // JSON.stringify drops named properties assigned to an array, so the sync
  // would report success and write the original file straight back.
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(
      `${modelsPath} must hold a JSON object at the top level, found ` +
      `${Array.isArray(parsed) ? "an array" : parsed === null ? "null" : typeof parsed}. ` +
      "Move it aside and re-run.",
    );
  }
  if (Array.isArray(parsed.providers)) {
    throw new Error(`${modelsPath} has a "providers" array; it must be an object. Move it aside and re-run.`);
  }
  if (!parsed.providers || typeof parsed.providers !== "object") parsed.providers = {};
  return parsed;
}

/**
 * Stands in for a user-supplied static token in `--print` output. The literal is
 * argv-derived taint, and printing it is the clear-text credential sink CodeQL
 * blocked in #2192 — `codeql-pr.yml` analyses `javascript-typescript` with no
 * path filter, so this file is in scope on every PR. The marker keeps the field
 * visible for inspection without putting the secret on stdout. (`--status` takes
 * the stricter route and omits the field entirely; see redactProviderForDisplay.)
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
  // Both `--flag value` and `--flag=value` spellings are accepted. A separated
  // value may not itself look like a flag, so `--token --print` leaves the token
  // unset instead of silently swallowing `--print` as credential material.
  const valueAt = (i) => (args[i + 1]?.startsWith("--") ? undefined : args[i + 1]);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--gateway-host" && valueAt(i)) opts.gatewayHost = args[++i];
    else if (args[i].startsWith("--gateway-host=")) opts.gatewayHost = args[i].slice("--gateway-host=".length);
    else if (args[i] === "--gateway-port" && valueAt(i)) opts.gatewayPort = args[++i];
    else if (args[i].startsWith("--gateway-port=")) opts.gatewayPort = args[i].slice("--gateway-port=".length);
    else if ((args[i] === "--token" || args[i] === "--api-key") && valueAt(i)) opts.token = args[++i];
    else if (args[i].startsWith("--token=")) opts.token = args[i].slice("--token=".length);
    else if (args[i].startsWith("--api-key=")) opts.token = args[i].slice("--api-key=".length);
  }
  opts.token = opts.token?.trim() || undefined;
  if (opts.help) {
    // Render the file header as help text. Bounded by the end of the comment
    // rather than a line count, so it cannot drift into printing import
    // statements at the user when the header grows.
    const source = fs.readFileSync(fileURLToPath(import.meta.url), "utf8");
    const header = source.slice(0, source.indexOf("*/")).split("\n").slice(2);
    console.log(header.map((line) => line.replace(/^\s*\* ?/u, "")).join("\n").trimEnd());
    console.log("\nOptions: --live --remove --status --print --token <token> --api-key <token> --gateway-host <host> --gateway-port <port> --help");
    process.exit(0);
  }
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const modelsPath = process.env.PRIME_MODELS_PATH ?? PRIME_MODELS_PATH;
  // Validate before any read or write, so a bad address never reaches models.json.
  const gatewayBase = gatewayBaseUrl(opts.gatewayHost, opts.gatewayPort);

  if (opts.status) {
    const data = readModelsJson(modelsPath);
    const entry = data.providers?.["openburnbar"];
    if (!entry) {
      console.log("openburnbar provider: not configured");
      console.log(`models.json: ${modelsPath}`);
      console.log(`gateway: ${gatewayBase}`);
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
    // In --print mode stdout carries only the document, so prose goes to stderr
    // and the preview shows the providers that actually survive the delete.
    const say = opts.print ? console.warn : console.log;
    if (data.providers["openburnbar"]) {
      delete data.providers["openburnbar"];
      if (!opts.print) writeModelsJson(modelsPath, data);
      say(`Removed openburnbar provider from ${modelsPath}`);
    } else {
      say("openburnbar provider not present — nothing to remove.");
    }
    if (opts.print) console.log(JSON.stringify(data, null, 2));
    process.exit(0);
  }

  const catalog = loadCatalog(repoRoot);
  let models;
  let source = "catalog";
  if (opts.live) {
    const liveIds = await fetchLiveModels(gatewayBase, opts.token);
    if (liveIds && liveIds.length > 0) {
      models = buildModelsFromLiveIds(liveIds, catalog);
      source = `live gateway ${gatewayBase}/models (${liveIds.length} models)`;
    } else {
      console.warn(`Live gateway not reachable at ${gatewayBase}/models — falling back to static catalog.`);
      models = buildModelsFromCatalog(catalog);
    }
  } else {
    models = buildModelsFromCatalog(catalog);
  }

  const providerEntry = {
    name: "OpenBurnBar Gateway",
    baseUrl: gatewayBase,
    api: "openai-completions",
    apiKey: opts.token ?? apiKeyShellCommand(),
    models,
  };

  if (opts.print) {
    // Two constraints on this surface: stdout stays pipeable into models.json,
    // and stdout never carries credential material. The default apiKey is the
    // shell resolver — no secret in the string — so it satisfies both. A --token
    // literal cannot, so it prints as a marker and the preview stops being a
    // usable config; that trade is announced on stderr rather than handing back
    // a file whose bearer token is the placeholder text.
    const printable = {
      ...providerEntry,
      apiKey: opts.token ? REDACTED_API_KEY_MARKER : providerEntry.apiKey,
    };
    if (opts.token) {
      console.warn("Note: --print redacts --token, so this preview is NOT a usable config.");
      console.warn("      Re-run without --print to install the static token.");
      console.warn("      For a pipeable secret-free config, drop --token and export OPENBURNBAR_GATEWAY_AUTH_TOKEN.");
    }
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
  console.log(`  gateway: ${gatewayBase}`);
  console.log(`  apiKey: ${opts.token ? "static token (passed via CLI)" : "shell command (resolves at request time from env/LaunchAgent plist)"}`);
  console.log(`\nVerify: prime-agent model list openburnbar | head`);
  console.log(`Try:     prime-agent --provider openburnbar --model ${models[0]?.id ?? "claude-sonnet-4-6"} -p "hello via burnbar"`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
