/**
 * Stable import surface for the canonical data-domain registry.
 *
 * `domains.generated.ts` is COPIED (never edited) from packages/data-domains/gen/domains.ts
 * by scripts/sync-domains.mjs on every predev/prebuild/pretest. Treat the registry
 * as the source of truth; edit registry.json + re-run codegen, never these files.
 */
export type {
  DataDomain,
  EncryptionTier,
  DomainAction,
} from "./domains.generated";

export {
  DATA_DOMAINS,
  DATA_DOMAIN_IDS,
  ENCRYPTION_TIERS,
  dataDomain,
} from "./domains.generated";

import type { EncryptionTier } from "./domains.generated";

/** Member-facing tier copy (short badge + the "who can read this" promise). */
export const TIER_META: Record<
  EncryptionTier,
  { label: string; badge: string; whoReads: string; tokenVar: string }
> = {
  server_readable: {
    label: "Server-readable",
    badge: "Operational",
    whoReads: "BurnBar can read this",
    tokenVar: "--color-tier-server-readable",
  },
  zero_access: {
    label: "Zero-access",
    badge: "Encrypted at rest",
    whoReads: "Encrypted — unlocked only under your device trust",
    tokenVar: "--color-tier-zero-access",
  },
  end_to_end: {
    label: "End-to-end",
    badge: "Only your devices",
    whoReads: "Only your devices can read this",
    tokenVar: "--color-tier-end-to-end",
  },
};

/** Human-readable retention copy. */
export const RETENTION_META: Record<string, string> = {
  rolling: "Rolling window",
  until_deleted: "Until you delete it",
  until_disconnected: "Until you disconnect",
  until_revoked: "Until you revoke access",
  permanent: "Kept while your account is active",
  append_only: "Append-only (tamper-evident)",
};

export function retentionLabel(retention: string): string {
  return RETENTION_META[retention] ?? retention;
}
