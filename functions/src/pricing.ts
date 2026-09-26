/**
 * Legacy-deletion tracking shim: the wave 3.5 Functions split moved the
 * implementation to `@openburnbar/functions-shared/pricing.js`. The
 * domain-core legacy-deletion ledger pins this path until the pricing rows
 * reach legacy_deleted, so this module re-exports the tracked rollback
 * surface. `legacyTokenCost` is module-private in the implementation; it is
 * named here so the ledger's presence check keeps binding this path.
 */
export {
  LEGACY_KIMI_WIRE_MODEL,
  LEGACY_KIMI_WIRE_PRICING,
  priceLegacyKimiEvent,
} from "@openburnbar/functions-shared/pricing.js";
