"use client";

/**
 * The BurnBar mark. Displays the brand logo icon framed as a soft
 * app-icon tile to sit elegantly on the paper.
 */
export function BrandMark({ size = 92 }: { size?: number }) {

  return (
    <span
      aria-hidden
      style={{
        position: "relative",
        display: "inline-grid",
        placeItems: "center",
        width: size,
        height: size,
        borderRadius: Math.round(size * 0.28),
        overflow: "hidden",
        background: "#ffffff",
        border: "1px solid var(--color-glass-line)",
        boxShadow:
          "0 1px 2px rgba(22,20,15,0.06), 0 14px 30px -16px rgba(22,20,15,0.5), inset 0 1px 0 rgba(255,255,255,0.8)",
      }}
    >
      <img
        src="/brand/burnbar-logo.png"
        alt="BurnBar"
        style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
      />
      <span className="brand-sheen" />
    </span>
  );
}
