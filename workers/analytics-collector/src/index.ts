import {
  AMPLITUDE_PROJECT,
  resolveAmplitudeProjectId,
} from "../../../analytics/funnel-contract";
import {
  applyCollectorRateLimit,
  collectorClientKey,
  collectorCorsHeaders,
  createMemoryRateLimiter,
  declaredCollectorBodyTooLarge,
  handleCollectorPost,
  readBoundedCollectorBody,
  type CollectorEnv,
  type CollectorRequestBody,
} from "./handler";

const fallbackCollectorRateLimit = createMemoryRateLimiter();

export default {
  async fetch(request: Request, env: CollectorEnv): Promise<Response> {
    const projectId = resolveAmplitudeProjectId(env.AMPLITUDE_PROJECT_ID ?? AMPLITUDE_PROJECT.development);
    const cors = collectorCorsHeaders(request.headers.get("origin"), projectId);
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405, headers: cors });
    }

    const limiter = env.COLLECTOR_RATE_LIMIT ?? fallbackCollectorRateLimit;
    const clientKey = collectorClientKey(request.headers);
    const verdict = await applyCollectorRateLimit({ ...env, COLLECTOR_RATE_LIMIT: limiter }, clientKey);
    if (!verdict.success) {
      return Response.json({ accepted: false, reason: "rate_limited" }, { status: 429, headers: cors });
    }
    if (declaredCollectorBodyTooLarge(request.headers.get("content-length"))) {
      return Response.json({ accepted: false, reason: "body_too_large" }, { status: 413, headers: cors });
    }
    const raw = await readBoundedCollectorBody(request);
    if (raw === null) {
      return Response.json({ accepted: false, reason: "body_too_large" }, { status: 413, headers: cors });
    }

    let body: CollectorRequestBody = {};
    try {
      body = JSON.parse(raw) as CollectorRequestBody;
    } catch {
      return Response.json({ accepted: false, reason: "invalid_json" }, { status: 400, headers: cors });
    }

    const result = await handleCollectorPost(
      body,
      {
        ...env,
        COLLECTOR_RATE_LIMIT: limiter,
      },
      (url, init) => fetch(url, init),
      request.headers.get("origin"),
      clientKey,
      { applyRateLimit: false },
    );
    if (result.status === 204) {
      return new Response(null, { status: 204, headers: cors });
    }
    return Response.json(result.body, { status: result.status, headers: cors });
  },
};
