# P17 Activity and Session Export

## Scope

The Linux Activity surface can export the session-index rows currently held by
the renderer in JSON or Markdown. The export is intentionally loaded-only: it
does not request older pages, session bodies, provider transcripts, tool state,
credentials, citations, or gateway metadata.

## Contract

- JSON and Markdown use the same versioned `loaded-session-index` document.
- The allowlist is `id`, `provider`, `model`, `startedAt`, `tokens`, `costUsd`,
  and `title` for each loaded row, plus source/count/timestamp metadata.
- Export filenames are normalized to a safe `openburnbar-*` basename with the
  selected `.json` or `.md` extension.
- Downloads use the WebView Blob/anchor handoff and fail closed when the
  browser download surface is unavailable.
- The visible scope note states that older or unloaded history is not fetched.

## QA

1. Load Activity with fixture mode and confirm the export control is enabled.
2. Select JSON, export, parse the file, and verify `scope` is
   `loaded-session-index`, `loadedCount` matches the loaded rows, and no
   unallowlisted fields are present.
3. Select Markdown and verify the loaded-only note plus each loaded row's
   provider, model, time, token, cost, and session ID.
4. Search or paginate Activity, export again, and verify only rows in the
   current in-memory `sessions` list are exported; no additional daemon call
   is made by export.
5. Use a title containing path separators and control characters in a fixture;
   verify the downloaded filename remains a single safe basename.
6. Run with browser Blob/object-URL APIs unavailable and verify a visible
   failure status is shown instead of attempting a renderer filesystem write.
