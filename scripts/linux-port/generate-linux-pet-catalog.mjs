import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, '../..');
export const MODELS_DIRECTORY = path.join(repoRoot, 'AgentLens', 'PetCompanion', 'Resources', 'Models');
export const PETS_DIRECTORY = path.join(repoRoot, 'AgentLens', 'PetCompanion', 'Resources', 'Pets');
export const CATALOG_OUTPUT = path.join(repoRoot, 'apps', 'linux-desktop', 'public', 'pets', 'catalog.json');

const SAFE_ID = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u;
const SAFE_GLB = /^[A-Za-z0-9][A-Za-z0-9._-]*\.glb$/u;
const SAFE_IMAGE = /^[A-Za-z0-9][A-Za-z0-9._-]*\.(?:webp|png)$/iu;

function assertSafe(value, pattern, label) {
  if (typeof value !== 'string' || !pattern.test(value)) {
    throw new Error(`${label} is unsafe: ${String(value)}`);
  }
}

function groupFor(definition) {
  const group = typeof definition.group === 'string' ? definition.group.trim() : '';
  if (group) return group;
  if (definition.id?.startsWith('founder-')) return 'Founders';
  if (definition.id?.startsWith('kawaii-')) return 'Kawaii Animals';
  return 'Legends';
}

function normalizedGLBName(value) {
  // Only append the optional extension. Never strip path components here:
  // a definition such as "../other.glb" or "nested/other.glb" must reach
  // the SAFE_GLB validation intact so it is rejected instead of silently
  // rebinding the pet to a different asset that shares the basename.
  const name = String(value);
  return name.toLowerCase().endsWith('.glb') ? name : `${name}.glb`;
}

function preferredModelForm(definition) {
  if (Array.isArray(definition.forms)) {
    const modelForm = definition.forms.find(
      (form) => form && form.kind === 'model3d' && typeof form.glb === 'string'
    );
    if (modelForm) return modelForm;
  }
  if (definition.model3d && typeof definition.model3d.glb === 'string') return definition.model3d;
  return null;
}

function atlasDefinition(definition, petDirectory) {
  const raw = definition.atlas2d;
  if (!raw || typeof raw !== 'object') return null;
  const image = typeof raw.image === 'string' ? raw.image : '';
  assertSafe(image, SAFE_IMAGE, `${definition.id} atlas image`);
  if (!existsSync(path.join(petDirectory, image))) {
    throw new Error(`${definition.id}: missing atlas image ${image}`);
  }
  const grid = raw.grid ?? {};
  const cell = raw.cell ?? {};
  const anchor = raw.anchor ?? {};
  const states = raw.states ?? {};
  if (!Number.isInteger(grid.cols) || !Number.isInteger(grid.rows) || grid.cols <= 0 || grid.rows <= 0) {
    throw new Error(`${definition.id}: invalid atlas grid`);
  }
  if (![cell.w, cell.h, anchor.x, anchor.y].every((value) => typeof value === 'number' && value > 0)) {
    throw new Error(`${definition.id}: invalid atlas geometry`);
  }
  const normalizedStates = Object.fromEntries(
    Object.entries(states).map(([name, value]) => {
      if (!value || typeof value !== 'object') throw new Error(`${definition.id}: invalid atlas state ${name}`);
      const state = value;
      if (
        !Number.isInteger(state.row) ||
        state.row < 0 ||
        !Number.isInteger(state.frames) ||
        state.frames < 1 ||
        !Number.isInteger(state.fps) ||
        state.fps < 1
      ) {
        throw new Error(`${definition.id}: invalid atlas state geometry ${name}`);
      }
      return [name, { row: state.row, frames: state.frames, fps: state.fps, loop: state.loop !== false, hero: state.hero === true }];
    })
  );
  if (!normalizedStates.idle) throw new Error(`${definition.id}: atlas must define idle`);
  return {
    image: `${definition.id}/${image}`,
    grid: { cols: grid.cols, rows: grid.rows },
    cell: { w: cell.w, h: cell.h },
    anchor: { x: anchor.x, y: anchor.y },
    defaultState: typeof raw.default === 'string' && raw.default ? raw.default : 'idle',
    states: normalizedStates,
    sockets: raw.sockets && typeof raw.sockets === 'object' ? raw.sockets : {}
  };
}

function modelDefinition(definition, modelsDirectory, petDirectory = null) {
  const form = preferredModelForm(definition);
  if (!form) return null;
  const glb = normalizedGLBName(form.glb);
  assertSafe(glb, SAFE_GLB, `${definition.id} GLB`);
  const modelPath = path.join(modelsDirectory, glb);
  const petModelPath = petDirectory ? path.join(petDirectory, glb) : null;
  if (!existsSync(modelPath) && (!petModelPath || !existsSync(petModelPath))) {
    throw new Error(`${definition.id}: missing GLB ${glb}`);
  }
  return {
    glb,
    modelKind: typeof form.modelKind === 'string' ? form.modelKind : typeof form.kind === 'string' ? form.kind : 'rigged',
    clipNames: Array.isArray(form.clipNames)
      ? form.clipNames.filter((clip) => typeof clip === 'string' && clip.length > 0)
      : []
  };
}

function mergeDefinition(definition, current, model, atlas) {
  const next = current ?? {
    id: definition.id,
    displayName:
      typeof definition.displayName === 'string' && definition.displayName.trim()
        ? definition.displayName.trim()
        : definition.name,
    group: groupFor(definition),
    description: typeof definition.description === 'string' ? definition.description : '',
    glb: undefined,
    modelKind: undefined,
    clipNames: [],
    defaultForm: undefined,
    atlas: undefined
  };
  if (model) {
    next.glb = model.glb;
    next.modelKind = model.modelKind;
    next.clipNames = model.clipNames;
  }
  if (atlas) next.atlas = atlas;
  next.defaultForm = atlas ? 'atlas2d' : next.glb ? 'model3d' : undefined;
  const normalized = {
    id: next.id,
    displayName: next.displayName,
    group: next.group,
    description: next.description,
    clipNames: next.clipNames,
    defaultForm: next.defaultForm
  };
  if (next.glb) normalized.glb = next.glb;
  if (next.modelKind) normalized.modelKind = next.modelKind;
  if (next.atlas) normalized.atlas = next.atlas;
  return normalized;
}

export async function buildCatalogFromDirectories(
  modelsDirectory = MODELS_DIRECTORY,
  petsDirectory = PETS_DIRECTORY
) {
  const byID = new Map();
  const modelEntries = await readdir(modelsDirectory, { withFileTypes: true });
  for (const entry of modelEntries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory()) continue;
    const definitionPath = path.join(modelsDirectory, entry.name, 'petdef.json');
    if (!existsSync(definitionPath)) continue;
    const definition = JSON.parse(await readFile(definitionPath, 'utf8'));
    assertSafe(definition.id, SAFE_ID, 'pet id');
    if (definition.id !== entry.name) throw new Error(`pet directory/id mismatch: ${entry.name} != ${definition.id}`);
    byID.set(definition.id, mergeDefinition(definition, byID.get(definition.id), modelDefinition(definition, modelsDirectory), null));
  }

  const petEntries = await readdir(petsDirectory, { withFileTypes: true });
  for (const entry of petEntries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory()) continue;
    const petDirectory = path.join(petsDirectory, entry.name);
    const definitionPath = path.join(petDirectory, 'petdef.json');
    if (!existsSync(definitionPath)) continue;
    const definition = JSON.parse(await readFile(definitionPath, 'utf8'));
    assertSafe(definition.id, SAFE_ID, 'pet id');
    if (definition.id !== entry.name) throw new Error(`pet directory/id mismatch: ${entry.name} != ${definition.id}`);
    const model = modelDefinition(definition, modelsDirectory, petDirectory);
    const atlas = atlasDefinition(definition, petDirectory);
    if (!model && !atlas) throw new Error(`${definition.id}: no supported pet form`);
    byID.set(definition.id, mergeDefinition(definition, byID.get(definition.id), model, atlas));
  }

  const pets = Array.from(byID.values())
    .filter((pet) => pet.defaultForm)
    .sort((a, b) => a.displayName.localeCompare(b.displayName) || a.id.localeCompare(b.id));
  if (!pets.length) throw new Error('No pet definitions found in the shared resources');
  return {
    schema: 'linux-pet-catalog/1',
    source: 'AgentLens/PetCompanion/Resources/{Models,Pets}',
    pets
  };
}

export const buildCatalogFromDirectory = buildCatalogFromDirectories;

export async function writeCatalog(outputPath = CATALOG_OUTPUT) {
  const catalog = await buildCatalogFromDirectories();
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(catalog, null, 2)}\n`, 'utf8');
  return catalog;
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : null;
if (invokedPath === import.meta.url) {
  const catalog = await writeCatalog();
  console.log(`Generated ${CATALOG_OUTPUT} (${catalog.pets.length} pets)`);
}
