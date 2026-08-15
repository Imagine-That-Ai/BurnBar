/**
 * Memory Power-Up wallet seam for usage-curation metering.
 *
 * Import `debitWallet` / `getWalletBalances` from this barrel. Do not add a
 * spend callable in this package — Fable owns usageCuration.ts.
 */

export {
  DEFAULT_MEMORY_PACKS,
  MEMORY_PACK_IDS,
  MEMORY_PACK_SCHEMA_VERSION,
  MEMORY_PACK_TTL_MS,
  defaultMemoryPack,
  isMemoryLane,
  isMemoryPackId,
  isMemoryPackProductID,
  memoryPackFromAppleProductID,
  memoryPackFromPlayProductID,
  memoryPackFromStripePriceID,
  memoryPackRuntimeIds,
} from "./catalog.js";

export type {
  MemoryLane,
  MemoryPackDefinition,
  MemoryPackId,
  MemoryPackSource,
} from "./catalog.js";

export {
  MemoryWalletInsufficientError,
  debitWallet,
  getWalletBalances,
  grantExists,
  grantMemoryPack,
  revokeGrant,
  reverseMemoryPackGrant,
  settlePendingMemoryPacks,
} from "./wallet.js";

export type {
  GrantMemoryPackResult,
  MemoryGrantStatus,
  MemoryWalletBalances,
} from "./walletTypes.js";
