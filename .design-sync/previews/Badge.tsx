import { Badge } from "@openburnbar/console";
import { ShieldCheck } from "lucide-react";

export const Tiers = () => (
  <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
    <Badge>Operational</Badge>
    <Badge tier="server_readable">Server-readable</Badge>
    <Badge tier="zero_access">Zero-access</Badge>
    <Badge tier="end_to_end">End-to-end</Badge>
  </div>
);

export const WithIcon = () => (
  <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
    <Badge tier="zero_access">
      <ShieldCheck style={{ width: 12, height: 12 }} />
      Encrypted at rest
    </Badge>
  </div>
);
