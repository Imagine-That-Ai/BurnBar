// Health check endpoint for burnbar.ai website.
// Returns 200 with JSON status for monitoring tools.
// Usage: curl https://burnbar.ai/health

export const prerender = true;

import type { APIRoute } from "astro";

export const GET: APIRoute = () => {
  const status = {
    status: "ok",
    service: "burnbar-website",
    timestamp: new Date().toISOString(),
    version: import.meta.env.PUBLIC_SITE_VERSION ?? "unknown",
    license: "AGPL-3.0-only",
    source: {
      repository: "https://github.com/Imagine-That-Ai/BurnBar",
      commit:
        import.meta.env.PUBLIC_SOURCE_COMMIT ?? import.meta.env.PUBLIC_SITE_VERSION ?? "unknown",
      correspondingSource: "https://burnbar.ai/legal/source"
    }
  };

  return new Response(JSON.stringify(status), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-cache, no-store, must-revalidate"
    }
  });
};
