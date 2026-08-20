// Report dataset endpoint for /bench/report.
//
// The report page's numbers — headline stats, the harness × model matrix,
// per-model profiles, strict-vs-solution flip counts, and per-task rates —
// recomputed from the evidence store at build time and served verbatim, so
// anyone can audit the rendered page against a stable JSON projection.
// Regenerates whenever the pipeline refreshes public/data/evidence.json.

export const prerender = true;

import type { APIRoute } from "astro";
import { reportDataset } from "../../data/bench";

export const GET: APIRoute = () =>
  new Response(JSON.stringify(reportDataset()), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      // Same freshness contract as the export it derives from.
      "Cache-Control": "no-cache, no-store, must-revalidate"
    }
  });
