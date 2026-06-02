"use client";

import { useState } from "react";
import Link from "next/link";
import { Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { TierBadge } from "./TierBadge";
import { ViewFlip, FlipToggle, type FlipSide } from "./ViewFlip";
import { DeleteDomainDialog } from "./DeleteDomainDialog";
import { exportUserData } from "@/lib/api";
import { retentionLabel, type DataDomain } from "@/lib/domains";
import { formatBytes, formatCount } from "@/lib/utils";

function FacetList({ items, empty }: { items: string[]; empty: string }) {
  if (items.length === 0) return <p className="text-xs italic text-content-dim">{empty}</p>;
  return (
    <ul className="flex flex-wrap gap-1.5">
      {items.map((it) => (
        <li
          key={it}
          className="rounded-pill border border-glass-line bg-mercury-wash px-2 py-0.5 text-xs text-content-base"
        >
          {it}
        </li>
      ))}
    </ul>
  );
}

/**
 * One inventory row per registry domain: tier badge, the yours<->server view-flip
 * (server side frosts the content), count/size, retention, and view/export/delete
 * actions gated by the domain's declared `actions`.
 */
export function DomainRow({
  domain,
  count,
  bytes,
  onChanged,
}: {
  domain: DataDomain;
  count: number;
  bytes: number;
  onChanged?: () => void;
}) {
  const [side, setSide] = useState<FlipSide>("yours");
  const [exporting, setExporting] = useState(false);
  const [exportError, setExportError] = useState<string | null>(null);

  const canExport = domain.actions.includes("export");
  const canDelete = domain.actions.includes("delete");
  const isPensieve = domain.id === "pensieve";

  const onExport = async () => {
    setExporting(true);
    setExportError(null);
    try {
      const res = await exportUserData([domain.id]);
      const blob = new Blob([JSON.stringify(res, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `burnbar-${domain.id}-export.json`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setExportError(err instanceof Error ? err.message : "Export failed.");
    } finally {
      setExporting(false);
    }
  };

  return (
    <div className="glass-pane p-token-4">
      <div className="flex flex-wrap items-start justify-between gap-token-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-token-2">
            <h3 className="font-display text-base text-content-bright">{domain.title}</h3>
            <TierBadge tier={domain.encryptionTier} />
          </div>
          <p className="mt-1 max-w-prose text-sm text-content-mute">{domain.summary}</p>
        </div>
        <FlipToggle side={side} onChange={setSide} />
      </div>

      <ViewFlip
        className="mt-token-3"
        side={side}
        yours={
          <div className="space-y-1.5">
            <p className="text-xs font-medium uppercase tracking-wide text-content-dim">
              Only your devices can read
            </p>
            <FacetList
              items={domain.deviceOnly}
              empty={
                domain.encryptionTier === "server_readable"
                  ? "Nothing extra is hidden — this domain is operational metadata."
                  : "No device-only facets declared."
              }
            />
          </div>
        }
        server={
          <div className="space-y-1.5">
            <p className="text-xs font-medium uppercase tracking-wide text-content-dim">
              What BurnBar&apos;s servers see
            </p>
            <FacetList items={domain.serverSees} empty="The server sees nothing here." />
          </div>
        }
      />

      <div className="mt-token-4 flex flex-wrap items-center justify-between gap-token-3">
        <dl className="flex flex-wrap gap-token-6 text-sm">
          <div>
            <dt className="text-xs text-content-dim">Items</dt>
            <dd className="font-mono text-content-bright">{formatCount(count)}</dd>
          </div>
          {domain.byteSource && (
            <div>
              <dt className="text-xs text-content-dim">Size</dt>
              <dd className="font-mono text-content-bright">{formatBytes(bytes)}</dd>
            </div>
          )}
          <div>
            <dt className="text-xs text-content-dim">Retention</dt>
            <dd className="text-content-base">{retentionLabel(domain.retention)}</dd>
          </div>
        </dl>

        <div className="flex flex-wrap items-center gap-token-2">
          {isPensieve && (
            <Button asChild variant="secondary" size="sm">
              <Link href="/pensieve">Open dashboard</Link>
            </Button>
          )}
          {canExport && (
            <Button variant="ghost" size="sm" onClick={onExport} disabled={exporting}>
              <Download className="size-3.5" />
              {exporting ? "Exporting…" : "Export"}
            </Button>
          )}
          {canDelete && <DeleteDomainDialog domain={domain} onDeleted={() => onChanged?.()} />}
        </div>
      </div>
      {exportError && (
        <p className="mt-token-2 text-xs text-[color:var(--color-seal-crimson)]">{exportError}</p>
      )}
    </div>
  );
}
