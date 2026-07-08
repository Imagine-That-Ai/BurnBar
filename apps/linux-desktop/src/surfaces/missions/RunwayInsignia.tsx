/** Runway mark — parity with macOS MissionsLaneView RunwayInsignia. */
export function RunwayInsignia({ size = 28 }: { size?: number }) {
  const stripeH = Math.round(size * 0.64);
  return (
    <span
      className="missions-runway-insignia"
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      <span className="missions-runway-insignia-stripe" style={{ height: stripeH }} />
    </span>
  );
}