export type LinuxPetCatalogEntry = {
  id: string;
  displayName: string;
  group: string;
  description: string;
  glb: string;
  modelKind: string;
  clipNames: string[];
};

export type LinuxPetCatalogDocument = {
  schema: 'linux-pet-catalog/1';
  source: string;
  pets: LinuxPetCatalogEntry[];
};

export const PET_CATALOG_URL = '/pets/catalog.json';
export const PET_SELECTION_STORAGE_KEY = 'openburnbar.linux.pet.selection.v1';
export const DEFAULT_PET_ID = 'kawaii-aurora-fox';
export const DEFAULT_PET_GLB = 'kawaii-aurora-fox-actions.glb';

const SAFE_ID = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u;
const SAFE_GLB = /^[A-Za-z0-9][A-Za-z0-9._-]*\.glb$/u;
export const PET_GROUP_ORDER = ['Family', 'Founders', 'Legends', 'Modern Icons', 'Kawaii Animals', 'Meshy'];

function requiredString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) throw new Error(`Pet catalog ${label} is invalid.`);
  return value.trim();
}

export function parsePetCatalog(raw: unknown): LinuxPetCatalogDocument {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Pet catalog is not an object.');
  const value = raw as Record<string, unknown>;
  if (value.schema !== 'linux-pet-catalog/1') throw new Error('Pet catalog schema is unsupported.');
  const source = requiredString(value.source, 'source');
  if (!Array.isArray(value.pets) || value.pets.length === 0 || value.pets.length > 256) {
    throw new Error('Pet catalog has an invalid pet list.');
  }

  const seen = new Set<string>();
  const pets = value.pets.map((rawPet, index) => {
    if (!rawPet || typeof rawPet !== 'object' || Array.isArray(rawPet)) {
      throw new Error(`Pet catalog entry ${index} is invalid.`);
    }
    const pet = rawPet as Record<string, unknown>;
    const id = requiredString(pet.id, `entry ${index} id`);
    const glb = requiredString(pet.glb, `${id} GLB`);
    if (!SAFE_ID.test(id) || seen.has(id)) throw new Error(`Pet catalog id is unsafe or duplicated: ${id}`);
    if (!SAFE_GLB.test(glb)) throw new Error(`${id} GLB name is unsafe.`);
    seen.add(id);
    const clipNames = Array.isArray(pet.clipNames)
      ? pet.clipNames.filter((clip): clip is string => typeof clip === 'string' && clip.length > 0)
      : [];
    return {
      id,
      displayName: requiredString(pet.displayName, `${id} display name`),
      group: requiredString(pet.group, `${id} group`),
      description: typeof pet.description === 'string' ? pet.description : '',
      glb,
      modelKind: typeof pet.modelKind === 'string' && pet.modelKind.trim() ? pet.modelKind : 'rigged',
      clipNames
    } satisfies LinuxPetCatalogEntry;
  });

  return { schema: 'linux-pet-catalog/1', source, pets };
}

export async function loadPetCatalog(fetcher: typeof fetch = fetch): Promise<LinuxPetCatalogDocument> {
  const response = await fetcher(PET_CATALOG_URL);
  if (!response.ok) throw new Error(`Pet catalog could not be loaded: ${response.status}`);
  return parsePetCatalog(await response.json());
}

export function petGroupNames(pets: LinuxPetCatalogEntry[]): string[] {
  const groups = new Set(pets.map((pet) => pet.group));
  return [
    ...PET_GROUP_ORDER.filter((group) => groups.has(group)),
    ...Array.from(groups).filter((group) => !PET_GROUP_ORDER.includes(group)).sort((a, b) => a.localeCompare(b))
  ];
}

export function filterPetCatalog(
  pets: LinuxPetCatalogEntry[],
  search: string,
  group: string | null
): LinuxPetCatalogEntry[] {
  const query = search.trim().toLocaleLowerCase();
  return pets
    .filter((pet) => group === null || pet.group === group)
    .filter((pet) => {
      if (!query) return true;
      return `${pet.displayName} ${pet.group} ${pet.id}`.toLocaleLowerCase().includes(query);
    })
    .sort((a, b) => a.displayName.localeCompare(b.displayName) || a.id.localeCompare(b.id));
}

export function readSelectedPetID(storage: Storage | undefined = globalThis.localStorage): string {
  try {
    const value = storage?.getItem(PET_SELECTION_STORAGE_KEY);
    return value && SAFE_ID.test(value) ? value : DEFAULT_PET_ID;
  } catch {
    return DEFAULT_PET_ID;
  }
}

export function persistSelectedPetID(id: string, storage: Storage | undefined = globalThis.localStorage): void {
  if (!SAFE_ID.test(id)) return;
  try {
    storage?.setItem(PET_SELECTION_STORAGE_KEY, id);
  } catch {
    // Selection persistence is a convenience; the in-memory choice still applies.
  }
}

export function resolveSelectedPet(
  pets: LinuxPetCatalogEntry[],
  selectedID: string
): LinuxPetCatalogEntry {
  return pets.find((pet) => pet.id === selectedID) ??
    pets.find((pet) => pet.id === DEFAULT_PET_ID) ??
    pets[0]!;
}
