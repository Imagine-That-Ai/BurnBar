"use client";

import { DomainRow } from "./DomainRow";
import { DATA_DOMAINS } from "@/lib/domains";
import { isFirstRunAccount } from "@/lib/accountStatus";
import { useDomainUsage, usageById } from "@/lib/useDomainUsage";

/**
 * The Transparency Inventory — one row per registry domain, in registry order.
 * Binds counts/sizes to getDataDomainUsage; missing domains report zero.
 */
export function TransparencyInventory() {
  const { data, loading, error, reload } = useDomainUsage();
  const byId = usageById(data);

  return (
    <section aria-labelledby="inventory-heading" className="space-y-token-4">
      <header className="flex flex-wrap items-end justify-between gap-token-3">
        <div>
          <h2 id="inventory-heading" className="font-display text-2xl text-content-bright">
            Transparency Inventory
          </h2>
          <p className="text-sm text-content-mute">
            Every kind of data BurnBar holds for you — what the server can read, what only your
            devices can, and how to take it back.
          </p>
        </div>
        {error && (
          <button
            type="button"
            onClick={reload}
            className="text-xs text-brass-core underline-offset-4 hover:underline"
          >
            Couldn&apos;t load usage — retry
          </button>
        )}
      </header>

      {!loading && isFirstRunAccount(data) && (
        <div className="border-y border-glass-line bg-mercury-wash px-token-4 py-token-3 text-sm leading-6 text-content-mute">
          Account ready. No Mac-published BurnBar data exists for this sign-in yet, so every
          inventory domain is currently empty.
        </div>
      )}

      <div className="space-y-token-3">
        {DATA_DOMAINS.map((domain) => {
          const u = byId[domain.id] ?? { count: 0, bytes: 0 };
          return (
            <DomainRow
              key={domain.id}
              domain={domain}
              count={loading ? 0 : u.count}
              bytes={loading ? 0 : u.bytes}
              onChanged={reload}
            />
          );
        })}
      </div>
    </section>
  );
}
