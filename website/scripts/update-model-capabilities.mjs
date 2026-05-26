import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SEED_DIR = path.join(ROOT, "scripts", "rundown-seed");
const MODELS_PATH = path.join(SEED_DIR, "models.json");
const CAPABILITIES_PATH = path.join(SEED_DIR, "model-capabilities.json");
const PUBLIC_MODELS_PATH = path.join(ROOT, "public", "data", "models.json");
const OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models?output_modalities=all";

const args = new Set(process.argv.slice(2));
const shouldApply = args.has("--apply");
const shouldCheck = args.has("--check");
const shouldRefreshOpenRouter = args.has("--refresh-openrouter");

if (!shouldApply && !shouldCheck && !args.has("--dry-run")) {
  console.log("[model-capabilities] dry run. Pass --apply to write or --check for CI drift checks.");
}

const [models, capabilityRows] = await Promise.all([
  readJSON(MODELS_PATH),
  readJSON(CAPABILITIES_PATH)
]);

if (shouldRefreshOpenRouter) {
  await refreshFromOpenRouter(capabilityRows);
}

const updatedModels = applyCapabilities(models, capabilityRows);
const changed = stableStringify(updatedModels) !== stableStringify(models);

if (shouldCheck && changed) {
  console.error("[model-capabilities] website/scripts/rundown-seed/models.json is missing capability updates.");
  process.exitCode = 1;
}

if (shouldApply) {
  await Promise.all([
    writeJSON(MODELS_PATH, updatedModels),
    writeJSON(PUBLIC_MODELS_PATH, updatedModels)
  ]);
  await writeJSON(CAPABILITIES_PATH, capabilityRows);
  console.log(`[model-capabilities] wrote ${relative(MODELS_PATH)}, ${relative(PUBLIC_MODELS_PATH)}, and ${relative(CAPABILITIES_PATH)}.`);
} else if (!shouldCheck) {
  const matched = updatedModels.filter((model) => model.modelCapabilities).length;
  console.log(`[model-capabilities] ${changed ? "would update" : "no drift in"} ${matched} model capability row(s).`);
}

function applyCapabilities(models, capabilityRows) {
  return models.map((model) => {
    const capabilityRow = capabilityRows.find((row) => rowMatchesModel(row, model));
    if (!capabilityRow?.modelCapabilities) {
      return model;
    }
    return {
      ...model,
      contextWindowTokens:
        capabilityRow.modelCapabilities.contextWindowTokens ?? model.contextWindowTokens,
      modelCapabilities: capabilityRow.modelCapabilities
    };
  });
}

async function refreshFromOpenRouter(capabilityRows) {
  const payload = await fetchJSONWithCurlFallback(OPENROUTER_MODELS_URL);
  const rows = Array.isArray(payload?.data) ? payload.data : [];
  for (const capabilityRow of capabilityRows) {
    const openRouterID = normalized(capabilityRow.openRouterModelID ?? capabilityRow.canonicalModelID);
    if (!openRouterID) {
      continue;
    }
    const liveRow = rows.find((row) => {
      const ids = [row.id, row.canonical_slug].map(normalized);
      return ids.includes(openRouterID);
    });
    if (!liveRow) {
      throw new Error(`OpenRouter did not return ${capabilityRow.openRouterModelID}.`);
    }
    capabilityRow.modelCapabilities = capabilitiesFromOpenRouter(liveRow, capabilityRow.modelCapabilities);
  }
}

function capabilitiesFromOpenRouter(liveRow, existing = {}) {
  const architecture = liveRow.architecture ?? {};
  const topProvider = liveRow.top_provider ?? {};
  const inputModalities = arrayOfStrings(architecture.input_modalities);
  const outputModalities = arrayOfStrings(architecture.output_modalities);
  const supportedParameters = arrayOfStrings(liveRow.supported_parameters);
  const sourceRefs = mergeSourceRefs(existing.sourceRefs ?? [], [
    {
      label: "OpenRouter /api/v1/models",
      url: "https://openrouter.ai/docs/api/api-reference/models/get-models"
    }
  ]);

  return {
    ...existing,
    schemaVersion: 1,
    inputModalities: inputModalities.length ? inputModalities : existing.inputModalities ?? ["text"],
    outputModalities: outputModalities.length ? outputModalities : existing.outputModalities ?? ["text"],
    supportedParameters,
    contextWindowTokens:
      positiveInteger(liveRow.context_length) ??
      positiveInteger(topProvider.context_length) ??
      existing.contextWindowTokens,
    maxOutputTokens:
      positiveInteger(topProvider.max_completion_tokens) ??
      positiveInteger(liveRow.per_request_limits?.max_completion_tokens) ??
      existing.maxOutputTokens,
    acceptedInputMimeTypes:
      existing.acceptedInputMimeTypes ??
      (inputModalities.includes("image") ? ["image/*"] : []),
    sourceRefs
  };
}

async function fetchJSONWithCurlFallback(url) {
  if (typeof fetch === "function") {
    try {
      const response = await fetch(url, {
        headers: {
          Accept: "application/json",
          "User-Agent": "OpenBurnBar model capability updater"
        }
      });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      return await response.json();
    } catch (error) {
      console.warn(`[model-capabilities] fetch failed, trying curl: ${error.message}`);
    }
  }
  const output = execFileSync("curl", ["-fsSL", url], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024
  });
  return JSON.parse(output);
}

function rowMatchesModel(row, model) {
  const modelKeys = [
    model.modelID,
    model.canonicalModelID,
    ...(Array.isArray(model.aliases) ? model.aliases : [])
  ].map(normalized);
  const rowKeys = [
    row.modelID,
    row.canonicalModelID,
    row.openRouterModelID,
    ...(Array.isArray(row.aliases) ? row.aliases : [])
  ].map(normalized);
  return modelKeys.some((key) => key && rowKeys.includes(key));
}

function normalized(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function arrayOfStrings(value) {
  return Array.isArray(value)
    ? value.filter((item) => typeof item === "string" && item.trim()).map((item) => item.trim())
    : [];
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

function mergeSourceRefs(existing, additions) {
  const seen = new Set();
  const merged = [];
  for (const sourceRef of [...existing, ...additions]) {
    const key = normalized(`${sourceRef.label}|${sourceRef.url}`);
    if (!key || seen.has(key)) {
      continue;
    }
    seen.add(key);
    merged.push(sourceRef);
  }
  return merged;
}

async function readJSON(filePath) {
  return JSON.parse(await fs.readFile(filePath, "utf8"));
}

async function writeJSON(filePath, value) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${stableStringify(value)}\n`);
}

function stableStringify(value) {
  return JSON.stringify(value, null, 2);
}

function relative(filePath) {
  return path.relative(ROOT, filePath);
}
