# PetGltf `vendor/` — three.js runtime (dev-host vendored)

`index.html` loads the three.js runtime from this folder via an ES-module import
map:

```
three                 -> ./vendor/three.module.js
three/addons/         -> ./vendor/addons/
draco decoder         -> ./vendor/draco/
```

These files are **vendored by the Windows dev-host / CI build step**, not committed
here — exactly the way the macOS SceneKit renderer relies on the platform Draco
decoder (`AgentLens/PetCompanion/Render/OpenBurnBarDracoDecompressor.mm`) rather
than bundling a decoder blob in source. Committing the ~1 MB minified three.js +
Draco WASM would bloat the repo and cannot be integrity-verified from the macOS
authoring host.

## What to place here (pinned)

Pin to a single three.js release (e.g. **r160**) and copy, byte-verbatim, from the
npm `three` package:

| Path | npm source (`node_modules/three/`) |
|------|-------------------------------------|
| `vendor/three.module.js` | `build/three.module.js` |
| `vendor/addons/loaders/GLTFLoader.js` | `examples/jsm/loaders/GLTFLoader.js` |
| `vendor/addons/loaders/DRACOLoader.js` | `examples/jsm/loaders/DRACOLoader.js` |
| `vendor/draco/` | `examples/jsm/libs/draco/` (the `draco_decoder.wasm` + `draco_wasm_wrapper.js`) |

The GLTFLoader `import 'three'` and `import '../utils/...'` specifiers resolve
through the import map / relative paths, so no bundler is required.

## Why Draco is mandatory

The shipped `.glb` clips (115 assets under
`AgentLens/PetCompanion/Resources/Models/`) are **Draco-compressed** — the same
compression the macOS `OpenBurnBarDracoDecompressor` decodes. three.js's
`DRACOLoader` decodes them in the WebView2 page, so `vendor/draco/` must be present
for any pet with compressed geometry to load.

## Verification split

- **macOS-verified:** `index.html` is embedded in `OpenBurnBar.App.Pet` and its
  bridge protocol (ready / load / clip / dispose / clipEnded) is exercised on the
  authoring host against a fake host (`windows/tests/pet`), plus a shell-extraction
  test that asserts the embedded HTML carries the import map + bridge hooks.
- **Windows dev-host / CI-deferred:** the live three.js render of a real `.glb`
  through `WebView2PetGltfHost`.
