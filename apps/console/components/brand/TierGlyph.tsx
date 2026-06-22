// Design-system grouping shim for /design-sync (claude.ai/design).
// The TierGlyph implementation lives in components/basin/TierGlyph.tsx; this
// re-export only exists so the design-system sync files it under the "Brand"
// group (the sync derives a component's group from its source directory).
// The app imports TierGlyph from its real path, not from here.
export { TierGlyph } from "@/components/basin/TierGlyph";
