const DEFAULT_MEM0_BASE = "https://api.mem0.ai";

function memoryPath(id) {
  return `/v1/memories/${encodeURIComponent(id)}/`;
}

export function makeMem0RestClient(apiKey, options = {}) {
  const {
    baseUrl = DEFAULT_MEM0_BASE,
    fetchImpl = globalThis.fetch,
    retryDelayMs = 500,
  } = options;
  if (typeof fetchImpl !== "function") {
    throw new Error("mem0 REST client requires a fetch implementation");
  }

  const headers = { Authorization: `Token ${apiKey}`, "Content-Type": "application/json" };

  async function call(method, path, body, callOptions = {}) {
    for (let attempt = 0; ; attempt++) {
      const res = await fetchImpl(`${baseUrl}${path}`, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });
      if (callOptions.allowNotFound && res.status === 404) return null;
      if (res.status === 429 || res.status >= 500) {
        if (attempt < 4) {
          await new Promise((resolve) => setTimeout(resolve, retryDelayMs * 2 ** attempt));
          continue;
        }
      }
      const txt = await res.text();
      if (!res.ok) throw new Error(`mem0 ${method} ${path} -> ${res.status}: ${txt.slice(0, 300)}`);
      return txt ? JSON.parse(txt) : null;
    }
  }

  return {
    get: (id) => call("GET", memoryPath(id), undefined, { allowNotFound: true }),
    async create(text, userId, appId, metadata) {
      const out = await call("POST", "/v1/memories/", {
        messages: [{ role: "user", content: text }],
        user_id: userId,
        app_id: appId,
        infer: false,
        metadata,
      });
      const id = out?.results?.[0]?.id;
      if (!id) {
        throw new Error(`create returned no memory id (verbatim add did not persist): ${JSON.stringify(out).slice(0, 200)}`);
      }
      return id;
    },
    delete: (id) => call("DELETE", memoryPath(id)),
  };
}
