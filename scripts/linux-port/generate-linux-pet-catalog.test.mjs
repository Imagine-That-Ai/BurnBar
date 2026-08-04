import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { CATALOG_OUTPUT, buildCatalogFromDirectory } from './generate-linux-pet-catalog.mjs';

test('generated Linux pet catalog mirrors every bundled 3D pet definition', async () => {
  const generated = JSON.parse(await readFile(CATALOG_OUTPUT, 'utf8'));
  const rebuilt = await buildCatalogFromDirectory();
  assert.deepEqual(generated, rebuilt);
  assert.equal(generated.schema, 'linux-pet-catalog/1');
  assert.equal(generated.pets.length, 110);
  assert.equal(new Set(generated.pets.map((pet) => pet.id)).size, generated.pets.length);
  assert.ok(generated.pets.every((pet) => /^[A-Za-z0-9][A-Za-z0-9._-]*\.glb$/u.test(pet.glb)));
});
