import { Lock, ShieldCheck, Eye } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { TIER_META } from "@/lib/domains";
import type { EncryptionTier } from "@/lib/domains";

const ICON: Record<EncryptionTier, typeof Lock> = {
  server_readable: Eye,
  zero_access: ShieldCheck,
  end_to_end: Lock,
};

export function TierBadge({ tier }: { tier: EncryptionTier }) {
  const meta = TIER_META[tier];
  const Icon = ICON[tier];
  return (
    <Badge tier={tier} title={meta.whoReads}>
      <Icon className="size-3" aria-hidden />
      {meta.badge}
    </Badge>
  );
}
