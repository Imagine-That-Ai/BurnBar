import { beforeEach, describe, expect, it } from 'vitest';
import {
  DEFAULT_PET_ID,
  PET_SELECTION_STORAGE_KEY,
  filterPetCatalog,
  parsePetCatalog,
  persistSelectedPetID,
  petGroupNames,
  readSelectedPetID,
  resolveSelectedPet
} from './petCatalog.js';
import type { LinuxPetCatalogEntry } from './petCatalog.js';

const pets = [
  { id: 'kawaii-aurora-fox', displayName: 'Aurora Fox', group: 'Kawaii Animals', description: '', defaultForm: 'model3d', glb: 'aurora.glb', modelKind: 'rigged', clipNames: [] },
  { id: 'ada-lovelace', displayName: 'Ada Lovelace', group: 'Legends', description: '', defaultForm: 'model3d', glb: 'ada.glb', modelKind: 'rigged', clipNames: [] },
  { id: 'family-riley', displayName: 'Riley', group: 'Family', description: '', defaultForm: 'model3d', glb: 'riley.glb', modelKind: 'rigged', clipNames: [] },
  {
    id: 'goose',
    displayName: 'Goose',
    group: 'Legends',
    description: '',
    defaultForm: 'atlas2d',
    clipNames: [],
    atlas: {
      image: 'goose/spritesheet.webp',
      grid: { cols: 8, rows: 9 },
      cell: { w: 192, h: 208 },
      anchor: { x: 96, y: 196 },
      defaultState: 'idle',
      states: { idle: { row: 0, frames: 8, fps: 8, loop: true, hero: false } }
    }
  }
] satisfies LinuxPetCatalogEntry[];

describe('Linux pet catalog', () => {
  beforeEach(() => localStorage.clear());

  it('validates the shared catalog wire shape and rejects unsafe names', () => {
    const catalog = parsePetCatalog({ schema: 'linux-pet-catalog/1', source: 'test', pets });
    expect(catalog.pets).toHaveLength(4);
    expect(() => parsePetCatalog({ schema: 'linux-pet-catalog/1', source: 'test', pets: [{ ...pets[0], glb: '../bad.glb' }] })).toThrow(
      /unsafe/
    );
    expect(() => parsePetCatalog({
      schema: 'linux-pet-catalog/1',
      source: 'test',
      pets: [{ ...pets[3], atlas: { ...pets[3].atlas!, image: 'other/spritesheet.webp' } }]
    })).toThrow(/geometry is invalid/);
  });

  it('filters by display name, id, and group in macOS picker order', () => {
    expect(filterPetCatalog(pets, 'ada', null).map((pet) => pet.id)).toEqual(['ada-lovelace']);
    expect(filterPetCatalog(pets, '', 'Family').map((pet) => pet.id)).toEqual(['family-riley']);
    expect(petGroupNames(pets)).toEqual(['Family', 'Legends', 'Kawaii Animals']);
  });

  it('persists and recovers the selected pet, with a safe default', () => {
    expect(readSelectedPetID()).toBe(DEFAULT_PET_ID);
    persistSelectedPetID('ada-lovelace');
    expect(localStorage.getItem(PET_SELECTION_STORAGE_KEY)).toBe('ada-lovelace');
    expect(readSelectedPetID()).toBe('ada-lovelace');
    expect(resolveSelectedPet(pets, 'missing').id).toBe(DEFAULT_PET_ID);
  });
});
