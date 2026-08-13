import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, '../..');
export const MODELS_DIRECTORY = path.join(repoRoot, 'AgentLens', 'PetCompanion', 'Resources', 'Models');
export const CATALOG_OUTPUT = path.join(repoRoot, 'apps', 'linux-desktop', 'public', 'pets', 'catalog.json');

const SAFE_ID = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u;
const SAFE_GLB = /^[A-Za-z0-9][A-Za-z0-9._-]*\.glb$/u;

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

export async function buildCatalogFromDirectory(modelsDirectory = MODELS_DIRECTORY) {
  const entries = await readdir(modelsDirectory, { withFileTypes: true });
  const pets = [];
  const seen = new Set();

  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory()) continue;
    const definitionPath = path.join(modelsDirectory, entry.name, 'petdef.json');
    if (!existsSync(definitionPath)) continue;

    const definition = JSON.parse(await readFile(definitionPath, 'utf8'));
    assertSafe(definition.id, SAFE_ID, 'pet id');
    if (definition.id !== entry.name) {
      throw new Error(`pet directory/id mismatch: ${entry.name} != ${definition.id}`);
    }
    if (seen.has(definition.id)) throw new Error(`duplicate pet id: ${definition.id}`);

    const form = preferredModelForm(definition);
    if (!form) throw new Error(`${definition.id}: no model3d form`);
    assertSafe(form.glb, SAFE_GLB, `${definition.id} GLB`);
    const glbPath = path.join(modelsDirectory, form.glb);
    if (!existsSync(glbPath)) throw new Error(`${definition.id}: missing GLB ${form.glb}`);

    const clipNames = Array.isArray(form.clipNames)
      ? form.clipNames.filter((clip) => typeof clip === 'string' && clip.length > 0)
      : [];
    pets.push({
      id: definition.id,
      displayName:
        typeof definition.displayName === 'string' && definition.displayName.trim()
          ? definition.displayName.trim()
          : definition.name,
      group: groupFor(definition),
      description: typeof definition.description === 'string' ? definition.description : '',
      glb: form.glb,
      modelKind: typeof form.modelKind === 'string' ? form.modelKind : 'rigged',
      clipNames
    });
    seen.add(definition.id);
  }

  if (!pets.length) throw new Error(`No pet definitions found in ${modelsDirectory}`);
  pets.sort((a, b) => a.displayName.localeCompare(b.displayName) || a.id.localeCompare(b.id));
  return {
    schema: 'linux-pet-catalog/1',
    source: 'AgentLens/PetCompanion/Resources/Models',
    pets
  };
}

export async function writeCatalog(outputPath = CATALOG_OUTPUT, modelsDirectory = MODELS_DIRECTORY) {
  const catalog = await buildCatalogFromDirectory(modelsDirectory);
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(catalog, null, 2)}\n`, 'utf8');
  return catalog;
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : null;
if (invokedPath === import.meta.url) {
  const catalog = await writeCatalog();
  console.log(`Generated ${CATALOG_OUTPUT} (${catalog.pets.length} pets)`);
}
