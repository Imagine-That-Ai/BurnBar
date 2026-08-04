export type PetAtlasState = {
  row: number;
  frames: number;
  fps: number;
  loop: boolean;
  hero: boolean;
};

export type PetAtlasDefinition = {
  image: string;
  grid: { cols: number; rows: number };
  cell: { w: number; h: number };
  anchor: { x: number; y: number };
  defaultState: string;
  states: Record<string, PetAtlasState>;
};

export type LinuxPetCatalogEntry = {
  id: string;
  displayName: string;
  group: string;
  description: string;
  defaultForm: 'model3d' | 'atlas2d';
  glb?: string;
  modelKind?: string;
  clipNames: string[];
  atlas?: PetAtlasDefinition;
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
const SAFE_ATLAS_IMAGE = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\/[A-Za-z0-9][A-Za-z0-9._-]*\.(?:webp|png)$/iu;
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
    if (!SAFE_ID.test(id) || seen.has(id)) throw new Error(`Pet catalog id is unsafe or duplicated: ${id}`);
    const defaultForm = pet.defaultForm;
    if (defaultForm !== 'model3d' && defaultForm !== 'atlas2d') {
      throw new Error(`${id} default form is unsupported.`);
    }
    const glb = typeof pet.glb === 'string' && pet.glb.length > 0 ? pet.glb : undefined;
    if (glb && !SAFE_GLB.test(glb)) throw new Error(`${id} GLB name is unsafe.`);
    const rawAtlas = pet.atlas;
    let atlas: PetAtlasDefinition | undefined;
    if (rawAtlas !== undefined) {
      if (!rawAtlas || typeof rawAtlas !== 'object' || Array.isArray(rawAtlas)) {
        throw new Error(`${id} atlas definition is invalid.`);
      }
      const atlasValue = rawAtlas as Record<string, unknown>;
      const image = requiredString(atlasValue.image, `${id} atlas image`);
      const grid = atlasValue.grid as Record<string, unknown> | undefined;
      const cell = atlasValue.cell as Record<string, unknown> | undefined;
      const anchor = atlasValue.anchor as Record<string, unknown> | undefined;
      const statesValue = atlasValue.states;
      if (
        !SAFE_ATLAS_IMAGE.test(image) ||
        image.split('/')[0] !== id ||
        !grid ||
        !cell ||
        !anchor ||
        typeof grid.cols !== 'number' ||
        typeof grid.rows !== 'number' ||
        !Number.isInteger(grid.cols) ||
        !Number.isInteger(grid.rows) ||
        grid.cols < 1 ||
        grid.rows < 1 ||
        typeof cell.w !== 'number' ||
        typeof cell.h !== 'number' ||
        cell.w <= 0 ||
        cell.h <= 0 ||
        typeof anchor.x !== 'number' ||
        typeof anchor.y !== 'number' ||
        anchor.x <= 0 ||
        anchor.y <= 0 ||
        !statesValue ||
        typeof statesValue !== 'object' ||
        Array.isArray(statesValue)
      ) {
        throw new Error(`${id} atlas geometry is invalid.`);
      }
      const states = Object.fromEntries(
        Object.entries(statesValue as Record<string, unknown>).map(([name, rawState]) => {
          if (!rawState || typeof rawState !== 'object' || Array.isArray(rawState)) {
            throw new Error(`${id} atlas state ${name} is invalid.`);
          }
          const state = rawState as Record<string, unknown>;
          if (
            !Number.isInteger(state.row) ||
            !Number.isInteger(state.frames) ||
            !Number.isInteger(state.fps) ||
            Number(state.row) < 0 ||
            Number(state.row) >= Number(grid.rows) ||
            Number(state.frames) < 1 ||
            Number(state.frames) > Number(grid.cols) ||
            Number(state.fps) < 1
          ) {
            throw new Error(`${id} atlas state ${name} has invalid timing.`);
          }
          return [name, {
            row: Number(state.row),
            frames: Number(state.frames),
            fps: Number(state.fps),
            loop: state.loop !== false,
            hero: state.hero === true
          } satisfies PetAtlasState];
        })
      ) as Record<string, PetAtlasState>;
      if (!states.idle) throw new Error(`${id} atlas is missing idle state.`);
      const defaultState = requiredString(atlasValue.defaultState, `${id} atlas default state`);
      if (!states[defaultState]) throw new Error(`${id} atlas default state is missing.`);
      atlas = {
        image,
        grid: { cols: Number(grid.cols), rows: Number(grid.rows) },
        cell: { w: Number(cell.w), h: Number(cell.h) },
        anchor: { x: Number(anchor.x), y: Number(anchor.y) },
        defaultState,
        states
      };
    }
    if (!glb && !atlas) throw new Error(`${id} has no supported form.`);
    seen.add(id);
    const clipNames = Array.isArray(pet.clipNames)
      ? pet.clipNames.filter((clip): clip is string => typeof clip === 'string' && clip.length > 0)
      : [];
    return {
      id,
      displayName: requiredString(pet.displayName, `${id} display name`),
      group: requiredString(pet.group, `${id} group`),
      description: typeof pet.description === 'string' ? pet.description : '',
      defaultForm,
      ...(glb ? { glb } : {}),
      ...(typeof pet.modelKind === 'string' && pet.modelKind.trim() ? { modelKind: pet.modelKind } : {}),
      clipNames,
      ...(atlas ? { atlas } : {})
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
