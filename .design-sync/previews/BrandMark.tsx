import { BrandMark } from "@openburnbar/console";

export const Default = () => (
  <div style={{ display: "flex", gap: 28, alignItems: "center", padding: 8 }}>
    <BrandMark />
    <BrandMark size={120} />
  </div>
);
