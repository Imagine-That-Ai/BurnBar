// Dashboard dataset endpoint for the /bench command center.
//
// The leaderboard tabs, match tuner, heatmap lens, and AI-chart renderer read
// this compact projection of the bench.json export at runtime. Serving it as
// a hashed-URL-free static JSON keeps the page's inline-script budget at zero
// (pages revalidate; immutable /data assets cache) and the CSP data-island
// free. Regenerates whenever the pipeline refreshes public/data/bench.json.

export const prerender = true;

import type { APIRoute } from "astro";
import { dashboardDataset } from "../../data/bench";

export const GET: APIRoute = () =>
  new Response(JSON.stringify(dashboardDataset()), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      // Same freshness contract as the export it derives from.
      "Cache-Control": "no-cache, no-store, must-revalidate"
    }
  });
