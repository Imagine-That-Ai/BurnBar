# Memory sync discoverability — capture evidence

Where memory sync lives after this change, rendered from the real SwiftUI views
inside the app process (`NSHostingView` + `cacheDisplay`, driven by a throwaway
hosted XCTest that is deliberately not committed — the same method as
`docs/evidence/onboarding-memory-step/`).

| File | What it shows |
|---|---|
| `devices-and-sync-landing.png` | Settings → **Devices & Sync**. The section headed "Sync" now has two rows: Cloud sync, and the new **Memory Sync** row with its live On/Off summary. This is the screen Alberto opened when he went looking; before this change it held only the conversation row. |
| `memory-sync-pane.png` | The canonical **Memory Sync** pane both entry points push. Honest one-liner, the "Back up approved memories" prerequisite, the "Sync memories to my other devices" sub-toggle behind its Pro veil, the git-project boundary note, and Team Memory. |
| `search-and-memory-pane.png` | Settings → General → **Search & Memory** (renamed from "Indexing & Search"). The on-device Memory controls stay here; the sync switches are replaced by one **Memory Sync** signpost row that opens the same pane. |

## What these renders do and do not show, honestly

- **No Data Vault entitlement resolves in a test host**, so
  `MacCloudEntitlementStore.cloudTier` is `.none` and both `LockedFeatureVeil`
  upsells are drawn. That is exactly what a member without Pro Max or Ultra
  sees, and the disabled switch is visible behind each veil. The unlocked state
  differs only in that the veil is absent and the switch is live.
- **No runtime context is wired**, so the Memory health card and the "Memory
  sync status" disclosure self-hide rather than dead-ending — the same
  behaviour they have in the app before the store is ready.
- In `search-and-memory-pane.png` the row *titles* render very pale. That is a
  capture artifact of drawing `GlassCard`'s material in an offscreen window with
  no app backdrop behind it, not the app's own contrast. The subtitles and the
  trailing "Off" value — which is what this image is evidence of — read
  normally.
- `devices-and-sync-landing.png` shows "None" trusted devices because the
  capture injects an offline device-trust gateway (there is no Firebase in the
  test host). That is the honest signed-out state.

## The click path

Old: Settings → General → **Indexing & Search** ("Local index, embeddings,
cross-encoder reranking") → scroll past four privacy toggles, the Memory
toggle, high-recall, Reset memory → "Back up approved memories" → "Sync
memories to my other devices".

New: Settings → **Devices & Sync** → **Sync** → **Memory Sync**. Or, from the
memory controls: Settings → General → **Search & Memory** → **Memory Sync**.
Both land on the same pane.
