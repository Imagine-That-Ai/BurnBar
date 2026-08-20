// Cell explorer dataset endpoint for /bench/report.
//
// Slim projection of the evidence store: one array per measured
// (harness × model × task) cell — table-indexed ids, integer pass counts,
// rounded medians. The report page's explorer fetches this lazily (only
// when the section scrolls into view or the user touches the controls),
// so the landing payload never pays for 684 rows the reader may never open.

export const prerender = true;

import type { APIRoute } from "astro";
import { cellsDataset } from "../../data/bench";

export const GET: APIRoute = () =>
  new Response(JSON.stringify(cellsDataset()), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      // Same freshness contract as the export it derives from.
      "Cache-Control": "no-cache, no-store, must-revalidate"
    }
  });
