# OpenBurnBar Extension

OpenBurnBar is a local-first sidebar companion for Cursor and VS Code. The extension talks to the OpenBurnBar daemon on the same machine and surfaces daemon health, run state, and workspace-aware recovery guidance.

## Status

This extension is part of OpenBurnBar's current **experimental source release**. It is intended for local development and early adopters rather than a polished marketplace install. There is no public VS Marketplace / Open VSX release or signed VSIX shipped from this repository today.

The repository already includes the annotated experimental source-release tag `v0.1.0-beta`.

## Build

```bash
npm ci
npm run build
```

## Test

```bash
npm run test:unit
npm run test:extension-host
```

## Packaging

The publish artifact is intentionally minimal: compiled runtime files under `dist/`, media assets, and package metadata.

Current release model:

- build locally from this repository
- load through your editor's local development / unpacked-extension flow
- do not assume a public marketplace listing or packaged install path yet
- tagged GitHub releases remain source-only and do not attach a signed VSIX or packaged extension artifact

## Repository

- Source: https://github.com/Ajnunezg/BurnBar
- Issues: https://github.com/Ajnunezg/BurnBar/issues

## Workspace trust

In restricted workspaces, the extension keeps read-only inspection features available and gates file-editing and terminal actions until the workspace is trusted. When those actions are available, the companion still constrains them to opened workspace roots, and `apply_patch` / `run_terminal` require explicit approval before dispatch.
