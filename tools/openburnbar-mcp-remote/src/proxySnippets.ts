import { anthropicGatewayUrl, LOCAL_CLIPROXY_KEY, openaiGatewayUrl } from "./proxyAuth.js";

export interface ProxySnippet {
  id: string;
  title: string;
  body: string;
  caveat: string;
}

function loopback(port: number): { openai: string; anthropic: string } {
  return { openai: openaiGatewayUrl(port), anthropic: anthropicGatewayUrl(port) };
}

export function proxySnippets(port = 8320): ProxySnippet[] {
  const { openai, anthropic } = loopback(port);
  return [
    {
      id: "grok",
      title: "Grok Build / SDK",
      body: `[model.openburnbar]
model = "grok-4.6"
base_url = "${openai}"
name = "OpenBurnBar Gateway"
env_key = "OPENBURNBAR_GATEWAY_TOKEN"
`,
      caveat: "Works standalone against xAI chat. Do not point env_key at the proxy process's XAI_API_KEY.",
    },
    {
      id: "droid-generic",
      title: "Droid generic chat",
      body: `{
  "customModels": [
    {
      "model": "grok-4.6",
      "id": "custom:OpenBurnBar-grok-4.6-0",
      "index": 0,
      "baseUrl": "${openai}",
      "apiKey": "${LOCAL_CLIPROXY_KEY}",
      "displayName": "OpenBurnBar grok-4.6",
      "maxOutputTokens": 8192,
      "provider": "generic-chat-completion-api"
    }
  ]
}
`,
      caveat: "Factory/Droid generic-chat-completion-api → POST /v1/chat/completions.",
    },
    {
      id: "droid-claude",
      title: "Droid Claude (Messages)",
      body: `{
  "customModels": [
    {
      "model": "claude-opus-5",
      "id": "custom:OpenBurnBar-claude-opus-5-0",
      "index": 0,
      "baseUrl": "${anthropic}",
      "apiKey": "${LOCAL_CLIPROXY_KEY}",
      "displayName": "OpenBurnBar claude-opus-5",
      "maxOutputTokens": 8192,
      "provider": "anthropic"
    }
  ]
}
`,
      caveat:
        "Droid's anthropic adapter appends /v1/messages to the origin URL. Needs a Messages-capable upstream (not standalone xAI). Forward to BurnBar on :8317 to translate.",
    },
    {
      id: "droid-openai",
      title: "Droid OpenAI (Responses)",
      body: `{
  "customModels": [
    {
      "model": "gpt-5.6-luna",
      "id": "custom:OpenBurnBar-gpt-5.6-luna-0",
      "index": 0,
      "baseUrl": "${openai}",
      "apiKey": "${LOCAL_CLIPROXY_KEY}",
      "displayName": "OpenBurnBar gpt-5.6-luna",
      "maxOutputTokens": 8192,
      "provider": "openai"
    }
  ]
}
`,
      caveat: "Factory openai adapter uses the Responses API. Standalone xAI serves POST /v1/responses.",
    },
    {
      id: "forge",
      title: "Forge",
      body: `[[providers]]
id = "openburnbar"
api_key_var = "OPENBURNBAR_GATEWAY_TOKEN"
url = "${openai}/chat/completions"
models = "${openai}/models"
response_type = "OpenAI"
`,
      caveat: "Matches OpenBurnBar Mac wiring keys. Chat completions only.",
    },
    {
      id: "opencode",
      title: "OpenCode",
      body: `{
  "provider": {
    "openburnbar": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OpenBurnBar Gateway",
      "options": {
        "baseURL": "${openai}",
        "apiKey": "${LOCAL_CLIPROXY_KEY}"
      },
      "models": {
        "grok-4.6": { "name": "grok-4.6" }
      }
    }
  }
}
`,
      caveat:
        "Mac-proven provider.openburnbar shape. Some OpenCode v2 builds also read settings.baseURL; that is a pointer, not a second source of truth.",
    },
    {
      id: "codex",
      title: "Codex CLI",
      body: `[model_providers.openburnbar]
name = "OpenBurnBar Gateway"
base_url = "${openai}"
env_key = "OPENBURNBAR_GATEWAY_TOKEN"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
`,
      caveat:
        "HTTP SSE is the default (`supports_websockets = false`). The gateway also accepts the Responses WebSocket on /v1/responses, so a Codex build that ignores the flag still works. Keep the flag false unless you want WS.",
    },
    {
      id: "claude-code",
      title: "Claude Code",
      body: `export ANTHROPIC_BASE_URL=${anthropic}
export ANTHROPIC_AUTH_TOKEN=${LOCAL_CLIPROXY_KEY}
export ANTHROPIC_MODEL=claude-opus-5
`,
      caveat:
        "Origin URL only — Claude Code appends /v1/messages. Pin ANTHROPIC_MODEL. Do not enable gateway model discovery; :8317 aliases are a BurnBar catalog feature. Needs a Messages-capable upstream or OPENBURNBAR_UPSTREAM=http://127.0.0.1:8317.",
    },
    {
      id: "pi",
      title: "Pi coding agent (client)",
      body: `{
  "openburnbar": {
    "baseUrl": "${openai}",
    "apiKey": "${LOCAL_CLIPROXY_KEY}",
    "api": "openai-completions",
    "models": [
      { "id": "grok-4.6", "name": "OpenBurnBar grok-4.6" }
    ]
  }
}
`,
      caveat:
        "Pi is a client of :8320 (~/.pi/agent/models.json). BurnBar's PiAgentRuntimeAdapter on :8765 is a Hermes sibling, not an OpenAI gateway. Do not document :8765 as Pi OpenAI.",
    },
    {
      id: "cursor",
      title: "Cursor BYOK",
      body: "No. Cursor BYOK requests originate at api2.cursor.sh; 127.0.0.1 is that backend's loopback, not yours. A loopback gateway cannot serve Cursor BYOK.",
      caveat: "Use BurnBar's Cloudflare tunnel path if you need Cursor. Do not paste 127.0.0.1 into Cursor settings.",
    },
  ];
}

export function allProxySnippetText(port = 8320): string {
  return proxySnippets(port)
    .map((snippet) => `${snippet.title}\n${snippet.body}\n${snippet.caveat}`)
    .join("\n");
}
