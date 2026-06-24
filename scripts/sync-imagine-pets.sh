#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

node --input-type=module <<'NODE'
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

const repoRoot = process.cwd();
const defaultPetsDir = path.resolve(repoRoot, "../imaginethat-llc/public/pet-models");
const remoteFallback = "https://imaginethat-llc.onrender.com/pet-models";
const sourceInput = process.env.IMAGINE_PETS_DIR || defaultPetsDir;
const strictSync = /^(1|true|yes)$/i.test(process.env.IMAGINE_PETS_SYNC_STRICT || "");
const allowRemoteSync = /^(1|true|yes)$/i.test(process.env.IMAGINE_PETS_SYNC_REMOTE || "");
const modelsDir = path.join(repoRoot, "AgentLens", "PetCompanion", "Resources", "Models");

function isURL(value) {
  return /^https?:\/\//.test(value);
}

function stripSlash(value) {
  return value.replace(/\/+$/, "");
}

async function readMaybeRemote(base, relativePath) {
  if (isURL(base)) {
    const url = `${stripSlash(base)}/${relativePath}`;
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`GET ${url} failed: ${response.status} ${response.statusText}`);
    }
    return Buffer.from(await response.arrayBuffer());
  }
  return readFile(path.join(base, ...relativePath.split("/")));
}

async function readManifest() {
  const attempts = [];
  const sources = [sourceInput];
  if ((allowRemoteSync || isURL(sourceInput)) && sourceInput !== remoteFallback) {
    sources.push(remoteFallback);
  }

  for (const source of sources) {
    try {
      const bytes = await readMaybeRemote(source, "pets-3d.json");
      return { source, pets: JSON.parse(bytes.toString("utf8")) };
    } catch (error) {
      attempts.push(`${source}: ${error.message}`);
      if (!isURL(source) && !strictSync && !allowRemoteSync && await hasBundledPetdefs()) {
        console.warn("Imagine pet sync skipped: local pets-3d.json is unavailable.");
        for (const attempt of attempts) console.warn(`  ${attempt}`);
        console.warn("Using bundled PetCompanion model resources. Set IMAGINE_PETS_SYNC_REMOTE=1 to refresh from the hosted manifest.");
        return null;
      }
    }
  }

  if (!strictSync && await hasBundledPetdefs()) {
    console.warn("Imagine pet sync skipped: pets-3d.json is unavailable.");
    for (const attempt of attempts) console.warn(`  ${attempt}`);
    console.warn("Using bundled PetCompanion model resources. Set IMAGINE_PETS_SYNC_STRICT=1 to fail on sync outages.");
    return null;
  }

  throw new Error(`Unable to read Imagine pet manifest:\n${attempts.join("\n")}`);
}

async function hasBundledPetdefs() {
  if (!existsSync(modelsDir)) return false;
  try {
    const entries = await readdir(modelsDir, { withFileTypes: true });
    return entries.some((entry) =>
      entry.isDirectory() && existsSync(path.join(modelsDir, entry.name, "petdef.json"))
    );
  } catch {
    return false;
  }
}

function assertSafeSlug(value, label) {
  if (!/^[a-z0-9][a-z0-9-]*[a-z0-9]$/.test(value)) {
    throw new Error(`${label} must be a safe slug: ${value}`);
  }
}

async function writeIfChanged(file, bytes) {
  if (existsSync(file)) {
    const current = await readFile(file);
    if (Buffer.compare(Buffer.from(bytes), current) === 0) return false;
  }
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, bytes);
  return true;
}

function assertPet(entry) {
  for (const key of ["id", "displayName", "group", "glb", "kind"]) {
    if (typeof entry[key] !== "string" || entry[key].length === 0) {
      throw new Error(`pets-3d.json entry is missing string field "${key}"`);
    }
  }
  if (!Array.isArray(entry.clips) || entry.clips.some((clip) => typeof clip !== "string" || clip.length === 0)) {
    throw new Error(`${entry.id}: "clips" must be a non-empty string array`);
  }
  assertSafeSlug(entry.id, "pet id");
  if (!entry.glb.endsWith(".glb")) {
    throw new Error(`${entry.id}: glb must be a .glb filename`);
  }
}

function manifestGlbPath(glb) {
  const relative = glb.replace(/^\/+/, "");
  const segments = relative.split("/");
  if (
    relative.includes("\\") ||
    segments.some((segment) =>
      segment.length === 0 ||
      segment === "." ||
      segment === ".." ||
      !/^[A-Za-z0-9._-]+$/.test(segment)
    )
  ) {
    throw new Error(`unsafe glb path in pets-3d.json: ${glb}`);
  }
  return relative.includes("/") ? relative : `opt/${relative}`;
}

function bundledGlbName(entry) {
  const relative = entry.glb.replace(/^\/+/, "");
  const baseName = path.basename(manifestGlbPath(entry.glb));
  if (!relative.includes("/")) return baseName;
  return `${entry.id}-${baseName}`;
}

function normalizedClips(entry) {
  if (
    entry.id === "alan-kay-smalltalk-paintbrush" &&
    entry.glb === "alan-kay-smalltalk-paintbrush-walk.glb"
  ) {
    return ["Armature|walking_man|baselayer"];
  }
  return entry.clips;
}

function clipMap(clips) {
  const available = new Set(clips);
  const first = clips[0] || "idle";
  const choose = (...candidates) => candidates.find((clip) => available.has(clip)) || (available.has("idle") ? "idle" : first);
  const mapped = {};

  for (const clip of clips) mapped[clip] = clip;

  mapped.idle = choose("idle", "walk", first);
  mapped.wander = choose("walk", "idle", first);
  mapped.drag = choose("walk", "idle", first);
  mapped.listen = choose("listen", "wave", "idle", first);
  mapped.greeting = choose("wave", "idle", first);
  mapped.think = choose("think", "confused", "clean", "scoop", "idle", first);
  mapped.speak = choose("nod", "listen", "wave", "clean", "scoop", "idle", first);
  mapped.work = choose("clean", "scoop", "idle", first);
  mapped.clean = choose("clean", "scoop", "idle", first);
  mapped.scoop = choose("scoop", "clean", "idle", first);
  mapped.react = choose("cheer", "clap", "jump", "dance", "celebrate", "wave", "idle", first);
  mapped.success = choose("victory", "cheer", "celebrate", "clap", "jump", "dance", "idle", first);
  mapped.question = choose("think", "confused", "clean", "scoop", "idle", first);
  mapped.praise = choose("cheer", "bow", "wave", "idle", first);
  mapped.hostile = choose("offended", "flinch", "stomp", "idle", first);
  mapped.dismiss = choose("retreat", "sleep", "doze", "idle", first);
  mapped.negate = choose("no", "shrug", "idle", first);
  mapped.failure = choose("sad", "confused", "shrug", "idle", first);
  mapped.hardError = choose("zap", "flinch", "sad", "idle", first);

  return Object.fromEntries(Object.entries(mapped).sort(([a], [b]) => a.localeCompare(b)));
}

// Persona sidecar (pet-personas.json), folded into petdef.agent so BurnBar's chat
// answers in the pet's own voice. Populated once the manifest source resolves;
// an absent sidecar simply leaves pets on BurnBar's default voice.
let personas = {};
// BurnBar-native persona overrides (scripts/pet-personas.burnbar.json) — same
// figures, re-grounded in BurnBar's world (tokens/spend/agents/code) so the pets
// don't confabulate a web-design context. Preferred per-id over the website voice.
let personasBurnbar = {};
function agentFor(id) {
  const p = personasBurnbar[id] || personas[id];
  if (!p) return undefined;
  return {
    persona: `${p.voice} A few phrases you're known for: ${(p.signature || []).join(" / ")}`,
    voiceLines: JSON.stringify(p.lines || {}),
  };
}

function petDefinition(entry) {
  const glbName = bundledGlbName(entry);
  const clips = normalizedClips(entry);
  const sourceLabel = entry.source ? `${entry.source} via Imagine That's 3D pet manifest` : `Imagine That's 3D pet manifest`;
  return {
    schema: "petdef/1",
    id: entry.id,
    name: entry.id,
    kind: "model3d",
    displayName: entry.displayName,
    group: entry.group,
    description: `Synced from ${sourceLabel} (${entry.glb}).`,
    forms: [
      {
        kind: "model3d",
        modelKind: entry.kind === "static" ? "static" : "rigged",
        glb: glbName,
        clipNames: clips,
        clips: clipMap(clips),
      },
    ],
    behavior: {
      initial: "idle",
      transitions: [
        { from: "idle", to: "wander", when: "cooldownElapsed", weight: 1 },
        { from: "wander", to: "idle", when: "idleElapsed", weight: 1 },
        { from: "idle", to: "listen", when: "inputFocused", weight: 1 },
        { from: "listen", to: "think", when: "sendPressed", weight: 1 },
        { from: "think", to: "speak", when: "streamStart", weight: 1 },
        { from: "speak", to: "react", when: "resultLanded", weight: 1 },
        { from: "think", to: "react", when: "fallbackFired", weight: 1 },
        { from: "react", to: "idle", when: "idleElapsed", weight: 1 },
      ],
    },
    agent: agentFor(entry.id),
    license: {
      ipStatus: "source-imaginethat-llc",
      licenseNote: "Synced one-way from imaginethat-llc public/pet-models.",
    },
  };
}

// Legacy demo-roster assets that live in Models/ but are NOT part of the Imagine
// manifest — the built-in demo pets (FormPicker.knownRoster) depend on them, so
// the manifest prune must never delete them even though no manifest entry claims
// them. Keeping this allowlist here fixes the "sync deletes go-gopher.glb /
// claudecode-crab.glb and breaks demo 3D" regression.
const KEEP_GLBS = new Set(["claudecode-crab.glb", "go-gopher.glb"]);

async function pruneStaleManifestOutputs(currentIDs, currentGlbs) {
  const entries = await readdir(modelsDir, { withFileTypes: true });
  let pruned = 0;

  for (const entry of entries) {
    const fullPath = path.join(modelsDir, entry.name);
    if (entry.isDirectory()) {
      const petdefPath = path.join(fullPath, "petdef.json");
      if (existsSync(petdefPath) && !currentIDs.has(entry.name)) {
        await rm(fullPath, { recursive: true, force: true });
        pruned += 1;
      }
    } else if (
      entry.isFile() &&
      entry.name.endsWith(".glb") &&
      !currentGlbs.has(entry.name) &&
      !KEEP_GLBS.has(entry.name)
    ) {
      await rm(fullPath, { force: true });
      pruned += 1;
    }
  }

  return pruned;
}

// Sync is OPT-IN. The committed PetCompanion model resources are the build's
// source of truth, so no automatic build (local, CI, or release) can silently
// regress model quality — e.g. overwriting the high-poly founder avatars with
// low-poly placeholders from a stale Imagine manifest. Refresh deliberately with
// IMAGINE_PETS_SYNC=1 (or the existing _REMOTE/_STRICT flags), then review the
// diff (including model quality) before committing.
const syncEnabled =
  /^(1|true|yes)$/i.test(process.env.IMAGINE_PETS_SYNC || "") ||
  allowRemoteSync ||
  strictSync;
if (!syncEnabled) {
  console.warn(
    "Imagine pet sync skipped (opt-in): using committed PetCompanion models. " +
    "Set IMAGINE_PETS_SYNC=1 to refresh from the Imagine manifest, then commit the reviewed diff."
  );
  process.exit(0);
}

const manifest = await readManifest();
if (!manifest) process.exit(0);

const { source, pets } = manifest;
if (!Array.isArray(pets)) {
  throw new Error("pets-3d.json root must be an array");
}

// Best-effort persona sidecar — pets keep BurnBar's default voice when it is absent.
try {
  const parsedPersonas = JSON.parse((await readMaybeRemote(source, "pet-personas.json")).toString("utf8"));
  personas = parsedPersonas && typeof parsedPersonas === "object" && !Array.isArray(parsedPersonas) ? parsedPersonas : {};
} catch {
  /* no pet-personas.json → default voice */
}

// BurnBar-local persona override — read from THIS repo (not the synced manifest),
// so BurnBar can tune voices independently of the website. Best-effort.
try {
  const bb = JSON.parse(await readFile(path.join(repoRoot, "scripts", "pet-personas.burnbar.json"), "utf8"));
  personasBurnbar = bb && typeof bb === "object" && !Array.isArray(bb) ? bb : {};
} catch {
  /* no scripts/pet-personas.burnbar.json → website personas */
}

await mkdir(modelsDir, { recursive: true });

const currentIDs = new Set();
const currentGlbs = new Set();
for (const pet of pets) {
  assertPet(pet);
  currentIDs.add(pet.id);
  currentGlbs.add(bundledGlbName(pet));
}

let copied = 0;
let written = 0;
for (const pet of pets) {
  assertPet(pet);
  const glbName = bundledGlbName(pet);
  const glbBytes = await readMaybeRemote(source, manifestGlbPath(pet.glb));
  if (await writeIfChanged(path.join(modelsDir, glbName), glbBytes)) copied += 1;

  const petdefBytes = Buffer.from(`${JSON.stringify(petDefinition(pet), null, 2)}\n`, "utf8");
  if (await writeIfChanged(path.join(modelsDir, pet.id, "petdef.json"), petdefBytes)) written += 1;
}

const pruned = await pruneStaleManifestOutputs(currentIDs, currentGlbs);

console.log(`Synced ${pets.length} Imagine 3D pets from ${source}`);
console.log(`GLBs copied/updated: ${copied}; petdefs written/updated: ${written}; stale outputs pruned: ${pruned}`);
NODE
