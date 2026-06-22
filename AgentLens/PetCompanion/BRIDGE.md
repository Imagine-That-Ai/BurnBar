# Imagine 3D Pet Bridge

One-way source of truth: `imaginethat-llc` owns the 3D pet GLBs and the canonical manifest. BurnBar only consumes the manifest.

## Add The Next Pet

1. Add a GLB to `imaginethat-llc/public/pet-models/opt/`.
2. Run `npm run pets:manifest` in `imaginethat-llc`.
3. Rebuild BurnBar.
4. The Xcode Run Script phase runs `scripts/sync-imagine-pets.sh`, copies the GLB, writes `Resources/Models/<id>/petdef.json`, and the pet appears in the picker with no Swift edits.

The generator picks the best available GLB per id:

- `<id>-actions.glb`: full rig with `idle, walk, wave, jump, clap, cheer, clean, scoop, dance`
- `<id>-walk.glb`: `idle, walk`
- `<id>.glb`: static `idle`

Groups come from the manifest:

- `founder-*` -> Founders
- known computing legends -> Legends
- `kawaii-*` and mascot ids -> Kawaii Animals

Override the local source during a build or manual sync with:

```bash
IMAGINE_PETS_DIR=/path/to/imaginethat-llc/public/pet-models scripts/sync-imagine-pets.sh
```

If the local manifest is missing, the sync falls back to:

```text
https://imaginethat-llc.onrender.com/pet-models
```
