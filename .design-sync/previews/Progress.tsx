import { Progress } from "@openburnbar/console";

function Row({ label, value, fillVar }: { label: string; value: number; fillVar?: string }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div style={{ fontSize: 13, marginBottom: 6, color: "var(--color-text-base)" }}>{label}</div>
      <Progress value={value} fillVar={fillVar} />
    </div>
  );
}

export const Levels = () => (
  <div style={{ width: 320 }}>
    <Row label="Documents · 20%" value={0.2} />
    <Row label="Photos · 55%" value={0.55} />
    <Row label="Messages · 85%" value={0.85} />
  </div>
);

export const OverQuota = () => (
  <div style={{ width: 320 }}>
    <Row label="Vault · 120% — over quota" value={1.2} />
  </div>
);

export const TierColored = () => (
  <div style={{ width: 320 }}>
    <Row label="End-to-end" value={0.7} fillVar="--color-tier-end-to-end" />
    <Row label="Zero-access" value={0.45} fillVar="--color-tier-zero-access" />
  </div>
);
