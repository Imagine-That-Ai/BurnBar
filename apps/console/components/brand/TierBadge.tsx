// Design-system grouping shim for /design-sync (claude.ai/design).
// The TierBadge implementation lives in components/inventory/TierBadge.tsx;
// this re-export only exists so the design-system sync files it under the
// "Brand" group (the sync derives a component's group from its source
// directory). The app imports TierBadge from its real path, not from here.
export { TierBadge } from "@/components/inventory/TierBadge";
