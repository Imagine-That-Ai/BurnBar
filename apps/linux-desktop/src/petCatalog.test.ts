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

const pets = [
  { id: 'kawaii-aurora-fox', displayName: 'Aurora Fox', group: 'Kawaii Animals', description: '', glb: 'aurora.glb', modelKind: 'rigged', clipNames: [] },
  { id: 'ada-lovelace', displayName: 'Ada Lovelace', group: 'Legends', description: '', glb: 'ada.glb', modelKind: 'rigged', clipNames: [] },
  { id: 'family-riley', displayName: 'Riley', group: 'Family', description: '', glb: 'riley.glb', modelKind: 'rigged', clipNames: [] }
];

describe('Linux pet catalog', () => {
  beforeEach(() => localStorage.clear());

  it('validates the shared catalog wire shape and rejects unsafe names', () => {
    const catalog = parsePetCatalog({ schema: 'linux-pet-catalog/1', source: 'test', pets });
    expect(catalog.pets).toHaveLength(3);
    expect(() => parsePetCatalog({ schema: 'linux-pet-catalog/1', source: 'test', pets: [{ ...pets[0], glb: '../bad.glb' }] })).toThrow(
      /unsafe/
    );
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
