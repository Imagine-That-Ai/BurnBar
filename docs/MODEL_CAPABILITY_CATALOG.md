# Model Capability Catalog

OpenBurnBar keeps model-specific input and output metadata separate from provider routing metadata.
Provider capabilities answer "can this route proxy a request"; model capabilities answer "what can this model accept".

## Source of truth

- Canonical public seed: `website/scripts/rundown-seed/model-capabilities.json`
- Website catalog mirror: `website/scripts/rundown-seed/models.json`
- Static app mirrors: `AgentLens/Resources/openburnbar_models.json` and `OpenBurnBarMobile/Resources/openburnbar_models.json`
- Runtime routing catalog: `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json`

Every model capability row uses `ModelIOCapabilities`:

- `inputModalities` and `outputModalities`
- `contextWindowTokens` and `maxOutputTokens`
- `acceptedInputMimeTypes`
- `supportedParameters`
- `sourceRefs`

## Refresh workflow

Run:

```bash
npm --prefix website run model-capabilities:update
```

The updater refreshes supported OpenRouter rows from `/api/v1/models?output_modalities=all`,
merges them into `model-capabilities.json`, then mirrors the payload into the website seed
and public `data/models.json`.

CI/drift check:

```bash
npm --prefix website run model-capabilities:check
```

When adding a new provider route, only mark a model as accepting images, audio, video, PDFs,
or files after the capability row has a source reference and the route preserves the matching
OpenAI-compatible content part through the gateway.
