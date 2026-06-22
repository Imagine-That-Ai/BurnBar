import { TierBadge } from "@openburnbar/console";

export const Tiers = () => (
  <div style={{ display: "flex", flexDirection: "column", gap: 10, alignItems: "flex-start" }}>
    <TierBadge tier="end_to_end" />
    <TierBadge tier="zero_access" />
    <TierBadge tier="server_readable" />
  </div>
);
