"use client";

import { useState } from "react";

/**
 * The BurnBar mark. Plays the looping brand video when present; until the video
 * asset is dropped in (public/brand/burnbar-mark.mp4) it falls back to the
 * static logo, so the sign-in never shows a broken frame. Framed as a soft
 * app-icon tile to sit elegantly on the paper.
 */
export function BrandMark({ size = 92 }: { size?: number }) {
  const [videoFailed, setVideoFailed] = useState(false);

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
      {!videoFailed ? (
        <video
          src="/brand/burnbar-mark.mp4"
          autoPlay
          muted
          loop
          playsInline
          onError={() => setVideoFailed(true)}
          style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
        />
      ) : (
        <>
          <img
            src="/brand/burnbar-logo.png"
            alt="BurnBar"
            style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
          />
          <span className="brand-sheen" />
        </>
      )}
    </span>
  );
}
