/**
 * Decorative aurora/editorial mesh backdrop. Purely presentational:
 * aria-hidden, pointer-events none, animation suppressed by the global
 * `body.reduced-motion *` rule. Colors follow the active skin tokens.
 */
export function MeshBackdrop() {
  return (
    <div className="mesh-backdrop" aria-hidden="true">
      <div className="mesh-blob mesh-blob-a" />
      <div className="mesh-blob mesh-blob-b" />
      <div className="mesh-blob mesh-blob-c" />
      <div className="mesh-grain" />
    </div>
  );
}
