/**
 * Legacy-deletion tracking shim: the wave 3.5 Functions split moved the
 * implementation to `@openburnbar/functions-shared/domainCorePricing.js`.
 * The domain-core legacy-deletion ledger pins this path until the pricing
 * rows reach legacy_deleted, so this module re-exports the tracked rollback
 * surface.
 */
export { resolveDomainCorePricingMode } from "@openburnbar/functions-shared/domainCorePricing.js";
