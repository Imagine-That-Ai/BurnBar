import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { CATALOG_OUTPUT, buildCatalogFromDirectory } from './generate-linux-pet-catalog.mjs';

test('generated Linux pet catalog mirrors every bundled 3D pet definition', async () => {
  const generated = JSON.parse(await readFile(CATALOG_OUTPUT, 'utf8'));
  const rebuilt = await buildCatalogFromDirectory();
  assert.deepEqual(generated, rebuilt);
  assert.equal(generated.schema, 'linux-pet-catalog/1');
  assert.equal(generated.pets.length, 114);
  assert.equal(new Set(generated.pets.map((pet) => pet.id)).size, generated.pets.length);
  assert.ok(generated.pets.some((pet) => pet.id === 'claudecode' && pet.defaultForm === 'atlas2d' && pet.atlas));
  assert.ok(generated.pets.some((pet) => pet.id === 'go-gopher' && pet.defaultForm === 'model3d' && pet.glb));
  assert.ok(generated.pets.every((pet) => pet.glb === undefined || /^[A-Za-z0-9][A-Za-z0-9._-]*\.glb$/u.test(pet.glb)));
});
