import { collectorCorsHeaders, handleCollectorPost, type CollectorEnv, type CollectorRequestBody } from "./handler";

export default {
  async fetch(request: Request, env: CollectorEnv): Promise<Response> {
    const cors = collectorCorsHeaders(request.headers.get("origin"));
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (request.method !== "POST") {
      return Response.json({ error: "method_not_allowed" }, { status: 405, headers: cors });
    }

    let body: CollectorRequestBody = {};
    try {
      body = (await request.json()) as CollectorRequestBody;
    } catch {
      return Response.json({ accepted: false, reason: "invalid_json" }, { status: 400, headers: cors });
    }

    const result = await handleCollectorPost(body, env, (url, init) => fetch(url, init));
    return Response.json(result.body, { status: result.status, headers: cors });
  },
};
