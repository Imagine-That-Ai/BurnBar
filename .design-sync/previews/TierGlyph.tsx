import { TierGlyph } from "@openburnbar/console";

function Cell({ children, label }: { children: React.ReactNode; label: string }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10 }}>
      {children}
      <span style={{ fontSize: 12, color: "var(--color-text-mute)" }}>{label}</span>
    </div>
  );
}

export const Tiers = () => (
  <div style={{ display: "flex", gap: 32, alignItems: "flex-end", padding: 8 }}>
    <Cell label="End-to-end">
      <TierGlyph glyph="shield" colorVar="--color-tier-end-to-end" size={46} />
    </Cell>
    <Cell label="Zero-access">
      <TierGlyph glyph="lock" colorVar="--color-tier-zero-access" size={46} />
    </Cell>
    <Cell label="Server-readable">
      <TierGlyph glyph="eye" colorVar="--color-tier-server-readable" size={46} />
    </Cell>
  </div>
);
