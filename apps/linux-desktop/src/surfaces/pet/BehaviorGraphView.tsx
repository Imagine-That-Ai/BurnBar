import { useId, useState } from 'react';
import type { PetBehaviorGraph } from '../../petBehaviorGraph.js';

const NODE_LAYOUT: Record<string, { x: number; y: number }> = {
  'idle-bob': { x: 72, y: 36 },
  'react-wave': { x: 228, y: 36 },
  'tier-gnome-contained': { x: 150, y: 128 },
  'tier-overlay-ok': { x: 150, y: 128 }
};

const BOX_W = 108;
const BOX_H = 36;

function nodeCenter(id: string): { cx: number; cy: number } {
  const pos = NODE_LAYOUT[id] ?? { x: 150, y: 80 };
  return { cx: pos.x + BOX_W / 2, cy: pos.y + BOX_H / 2 };
}

function arrowPath(fromId: string, toId: string): string {
  const from = nodeCenter(fromId);
  const to = nodeCenter(toId);
  const dx = to.cx - from.cx;
  const dy = to.cy - from.cy;
  const len = Math.hypot(dx, dy) || 1;
  const ux = dx / len;
  const uy = dy / len;
  const start = { x: from.cx + ux * (BOX_W / 2 - 4), y: from.cy + uy * (BOX_H / 2 - 4) };
  const end = { x: to.cx - ux * (BOX_W / 2 - 4), y: to.cy - uy * (BOX_H / 2 - 4) };
  return `M ${start.x} ${start.y} L ${end.x} ${end.y}`;
}

function kindClass(kind: string): string {
  if (kind === 'idle') return 'pet-graph-node--idle';
  if (kind === 'react') return 'pet-graph-node--react';
  return 'pet-graph-node--tier';
}

/**
 * SVG behavior graph for the pet companion; raw JSON remains behind disclosure for evidence.
 */
export function BehaviorGraphView({ graph }: { graph: PetBehaviorGraph }) {
  const [showRaw, setShowRaw] = useState(false);
  const titleId = useId();
  const edges: { key: string; from: string; to: string }[] = [];
  for (const node of graph.nodes) {
    for (const next of node.next) {
      edges.push({ key: `${node.id}->${next}`, from: node.id, to: next });
    }
  }

  return (
    <section className="pet-behavior-section" aria-labelledby={titleId}>
      <h3 id={titleId} className="pet-section-title">
        Behavior graph
      </h3>
      <svg
        className="pet-behavior-svg"
        viewBox="0 0 360 180"
        role="img"
        aria-label="Pet behavior state graph with idle, react, and tier nodes"
      >
        <defs>
          <marker
            id="pet-graph-arrow"
            markerWidth="8"
            markerHeight="8"
            refX="6"
            refY="4"
            orient="auto"
          >
            <path d="M0,0 L8,4 L0,8 Z" className="pet-graph-arrowhead" />
          </marker>
        </defs>
        {edges.map((edge) => (
          <path
            key={edge.key}
            d={arrowPath(edge.from, edge.to)}
            className="pet-graph-edge"
            markerEnd="url(#pet-graph-arrow)"
            fill="none"
          />
        ))}
        {graph.nodes.map((node) => {
          const pos = NODE_LAYOUT[node.id] ?? { x: 120, y: 72 };
          return (
            <g key={node.id} className={`pet-graph-node ${kindClass(node.kind)}`}>
              <rect
                x={pos.x}
                y={pos.y}
                width={BOX_W}
                height={BOX_H}
                rx={8}
                className="pet-graph-node-box"
              />
              <text
                x={pos.x + BOX_W / 2}
                y={pos.y + BOX_H / 2}
                className="pet-graph-node-label"
                textAnchor="middle"
                dominantBaseline="central"
              >
                {node.label}
              </text>
            </g>
          );
        })}
      </svg>
      <button
        type="button"
        className="pet-raw-toggle"
        aria-expanded={showRaw}
        onClick={() => setShowRaw((open) => !open)}
      >
        {showRaw ? 'Hide raw graph' : 'Show raw graph'}
      </button>
      {showRaw ? (
        <pre className="pet-graph">{JSON.stringify(graph.nodes, null, 2)}</pre>
      ) : null}
    </section>
  );
}