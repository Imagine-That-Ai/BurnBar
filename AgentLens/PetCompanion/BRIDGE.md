# Imagine 3D Pet Bridge

One-way source of truth: `imaginethat-llc` owns the 3D pet GLBs and the canonical manifest. BurnBar only consumes the manifest.

## Add The Next Pet

1. Add a GLB to `imaginethat-llc/public/pet-models/opt/`.
2. Run `npm run pets:manifest` in `imaginethat-llc`.
3. Rebuild BurnBar.
4. The Xcode Run Script phase runs `scripts/sync-imagine-pets.sh`, copies the GLB, writes `Resources/Models/<id>/petdef.json`, and the pet appears in the picker with no Swift edits.

The generator picks the best available GLB per id and writes the clip names the
GLB actually carries. BurnBar reads `clips[]` dynamically; do not add Swift code
for new clip names.

- `<id>-actions.glb`: rigged pet with the manifest's full emote list
- `<id>-walk.glb`: `idle, walk`
- `<id>.glb`: static `idle`

The current reaction vocabulary is documented in `imaginethat-llc/docs/PET-REACTIONS.md`.
The sync writes both:

- `model3d.clipNames`: the raw manifest `clips[]`, verbatim
- `model3d.clips`: petcore's semantic clip map, including every raw clip plus compatibility aliases

Groups come from the manifest:

- `founder-*` -> Founders
- known computing legends -> Legends
- `kawaii-*` and mascot ids -> Kawaii Animals

Meshy-backed pets use the same manifest contract. The producer should keep ids stable across nightly runs; use `meshy-<full-task-id>` as the pet id, `displayName` from Meshy's `name`, and `group: "Family"` for family/personal pets such as Riley. Other Meshy stream pets can use `group: "Meshy"` unless they are intentionally assigned to Founders, Legends, or Kawaii Animals. BurnBar preserves the manifest group and also displays unknown future groups dynamically.

Override the local source during a build or manual sync with:

```bash
IMAGINE_PETS_DIR=/path/to/imaginethat-llc/public/pet-models scripts/sync-imagine-pets.sh
```

If the local manifest is missing, the sync falls back to:

```text
https://imaginethat-llc.onrender.com/pet-models
```

If neither source is available and BurnBar already has bundled petdefs, the
build keeps using those bundled pets. Set `IMAGINE_PETS_SYNC_STRICT=1` when a
missing manifest should fail the build.
