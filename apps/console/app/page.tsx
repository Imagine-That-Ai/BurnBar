"use client";

import Link from "next/link";
import { Basin } from "@/components/basin/Basin";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { useAuth } from "@/lib/useAuth";
import { useDomainUsage } from "@/lib/useDomainUsage";
import { DATA_DOMAINS } from "@/lib/domains";
import { formatBytes, formatCount } from "@/lib/utils";

export default function HomePage() {
  const { user } = useAuth();
  const { data } = useDomainUsage();

  const totals = (data?.domains ?? []).reduce(
    (acc, d) => ({ count: acc.count + d.count, bytes: acc.bytes + d.bytes }),
    { count: 0, bytes: 0 },
  );

  return (
    <div className="space-y-token-8">
      <section className="space-y-token-4 text-center">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-content-dim">
          {user?.email ?? "Your account"}
        </p>
        <h1 className="font-display text-4xl text-content-bright">The Basin</h1>
        <p className="mx-auto max-w-xl text-content-mute">
          Everything BurnBar holds for you, rendered as swirling mercury — one eddy per kind of
          data, sized by how much there is, tinted by who can read it.
        </p>
      </section>

      <Card className="overflow-hidden p-0">
        <Basin usage={data} />
      </Card>

      <div className="grid gap-token-3 sm:grid-cols-3">
        <Stat label="Domains" value={String(DATA_DOMAINS.length)} />
        <Stat label="Total items" value={formatCount(totals.count)} />
        <Stat label="Tracked size" value={formatBytes(totals.bytes)} />
      </div>

      <div className="flex flex-wrap justify-center gap-token-3">
        <Button asChild>
          <Link href="/inventory">Open the Transparency Inventory</Link>
        </Button>
        <Button asChild variant="secondary">
          <Link href="/escrow">Trust this browser</Link>
        </Button>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <Card className="text-center">
      <CardContent className="pt-0">
        <p className="font-mono text-2xl text-content-bright">{value}</p>
        <p className="text-xs uppercase tracking-wide text-content-dim">{label}</p>
      </CardContent>
    </Card>
  );
}
