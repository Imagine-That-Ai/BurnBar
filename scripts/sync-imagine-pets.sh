#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

node --input-type=module <<'NODE'
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

const repoRoot = process.cwd();
const defaultPetsDir = path.resolve(repoRoot, "../imaginethat-llc/public/pet-models");
const remoteFallback = "https://imaginethat-llc.onrender.com/pet-models";
const sourceInput = process.env.IMAGINE_PETS_DIR || defaultPetsDir;
const strictSync = /^(1|true|yes)$/i.test(process.env.IMAGINE_PETS_SYNC_STRICT || "");
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
  const sources = sourceInput === remoteFallback ? [sourceInput] : [sourceInput, remoteFallback];
  for (const source of sources) {
    try {
      const bytes = await readMaybeRemote(source, "pets-3d.json");
      return { source, pets: JSON.parse(bytes.toString("utf8")) };
    } catch (error) {
      attempts.push(`${source}: ${error.message}`);
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
  if (!entry.glb.endsWith(".glb")) {
    throw new Error(`${entry.id}: glb must be a .glb filename`);
  }
}

function manifestGlbPath(glb) {
  const relative = glb.replace(/^\/+/, "");
  if (relative.includes("..")) {
    throw new Error(`unsafe glb path in pets-3d.json: ${glb}`);
  }
  return relative.includes("/") ? relative : `opt/${relative}`;
}

function bundledGlbName(glb) {
  return path.basename(manifestGlbPath(glb));
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

function petDefinition(entry) {
  const glbName = bundledGlbName(entry.glb);
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
        clipNames: entry.clips,
        clips: clipMap(entry.clips),
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
    license: {
      ipStatus: "source-imaginethat-llc",
      licenseNote: "Synced one-way from imaginethat-llc public/pet-models.",
    },
  };
}

const manifest = await readManifest();
if (!manifest) process.exit(0);

const { source, pets } = manifest;
if (!Array.isArray(pets)) {
  throw new Error("pets-3d.json root must be an array");
}

await mkdir(modelsDir, { recursive: true });

let copied = 0;
let written = 0;
for (const pet of pets) {
  assertPet(pet);
  const glbName = bundledGlbName(pet.glb);
  const glbBytes = await readMaybeRemote(source, manifestGlbPath(pet.glb));
  if (await writeIfChanged(path.join(modelsDir, glbName), glbBytes)) copied += 1;

  const petdefBytes = Buffer.from(`${JSON.stringify(petDefinition(pet), null, 2)}\n`, "utf8");
  if (await writeIfChanged(path.join(modelsDir, pet.id, "petdef.json"), petdefBytes)) written += 1;
}

console.log(`Synced ${pets.length} Imagine 3D pets from ${source}`);
console.log(`GLBs copied/updated: ${copied}; petdefs written/updated: ${written}`);
NODE
