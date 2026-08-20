/**
 * @fileoverview Display catalog for the ten pre-registered experiential
 * Arena tasks (BurnBench tasks 40–49). Keyed by task_id as served by the
 * `arenaMatchup` callable. The copy is faithful to each task's prompt.md —
 * including its "Quality bar (human-judged)" section where one exists — so
 * voters judge against the same brief the agents were given. Showing the
 * brief cannot leak identities: both sides ran the identical task.
 */

export interface ArenaTaskBrief {
  /** Short human title, e.g. "SVG Landscape Scene". */
  title: string;
  /** One-to-two sentence summary of what the agents were asked to build. */
  brief: string;
  /** Judging hints, rendered after "Judge on:". */
  judgeOn: string[];
}

export const ARENA_TASKS: Record<string, ArenaTaskBrief> = {
  "40_svg_scene": {
    title: "SVG Landscape Scene",
    brief:
      "Hand-author a rich landscape as a single self-contained SVG: gradient sky, a sun or moon, " +
      "layered mountain ridges, and a foreground — at least 40 shapes and 3 gradients, no external anything.",
    judgeOn: ["artistry", "depth & layering", "gradient craft", "scene richness"]
  },
  "41_svg_icon_set": {
    title: "SVG Icon Set",
    brief:
      "Design a cohesive six-icon set (home, search, settings, bell, user, heart) on a 24×24 grid " +
      "with one consistent stroke style across all icons.",
    judgeOn: ["instant recognizability", "optical consistency", "visual weight", "path craft"]
  },
  "42_canvas_generative": {
    title: "Seeded Generative Art",
    brief:
      "Build a canvas artwork driven entirely by a deterministic seeded PRNG — same seed, identical " +
      "image — with a seed input, re-render button, and ?seed= URL support, in at least three visual layers.",
    judgeOn: ["beauty", "layering", "seed controls actually work (try the same seed twice)"]
  },
  "43_threejs_orrery": {
    title: "3D Solar-System Orrery",
    brief:
      "An interactive Three.js solar system: the sun plus all eight named planets on visible orbit " +
      "rings, a speed control with pause, and drag-to-orbit camera.",
    judgeOn: ["completeness (8 planets, labels, rings)", "camera feel", "polish"]
  },
  "44_threejs_product": {
    title: "3D Product Viewer",
    brief:
      "A stylized desk lamp modeled from 6+ Three.js primitives, with hand-written orbit/zoom " +
      "controls (no addons allowed), two-plus lighting, and at least three color variants.",
    judgeOn: ["model craft", "control feel", "lighting", "presentation"]
  },
  "45_game_breakout": {
    title: "Breakout (playable)",
    brief:
      "A complete, playable Breakout: paddle steered by keyboard AND mouse, angle-controlled bounces, " +
      "5+ brick rows, score, three lives, and win/lose screens with restart.",
    judgeOn: ["game feel", "ball physics", "juice & polish", "HUD clarity"]
  },
  "46_game_2048": {
    title: "2048 (playable)",
    brief:
      "A faithful, playable 2048: 4×4 grid, arrow-key slides, correct merge rules, score, " +
      "win acknowledgement, game-over detection, and restart.",
    judgeOn: ["fidelity to the original's feel", "transitions", "color ramp", "typography"]
  },
  "47_simgame_grid_quest": {
    title: "Grid Quest (policy replay)",
    brief:
      "An agent-written policy plays a 12×12 grid world: collect 3 keys, unlock the doors, dodge " +
      "deadly hazards, reach the exit. You're watching an animated replay of its actual attempts.",
    judgeOn: ["did it escape?", "path efficiency", "hazard avoidance", "keys before doors"]
  },
  "48_ui_landing": {
    title: 'Landing Page ("EmberStack")',
    brief:
      "A responsive, dark-themed marketing page for a fictional dev tool: hero with call-to-action, " +
      "3+ features, three pricing tiers with one highlighted, and a footer.",
    judgeOn: ["design quality", "visual hierarchy", "responsiveness (resize it)", "copy"]
  },
  "49_ui_dashboard": {
    title: "Analytics Dashboard",
    brief:
      "A dark-themed dashboard: sidebar navigation, 4+ KPI cards, a line chart hand-drawn on canvas " +
      "(no chart libraries), and a plausible 5+ row data table.",
    judgeOn: ["information design", "chart craft", "polish", "responsiveness"]
  }
};

const FALLBACK_BRIEF: ArenaTaskBrief = {
  title: "Blind matchup",
  brief: "Both agents ran the same experiential task under identical rules.",
  judgeOn: ["overall quality"]
};

/** Display brief for a task id, with a safe fallback for unknown ids. */
export function arenaTaskBrief(taskId: string): ArenaTaskBrief {
  return ARENA_TASKS[taskId] ?? FALLBACK_BRIEF;
}
