import {
  anthropicGatewayUrl,
  DEFAULT_PROXY_HOST,
  DEFAULT_PROXY_PORT,
  LOCAL_CLIPROXY_KEY,
  openaiGatewayUrl,
  type ProxyOptions,
} from "./proxyAuth.js";
import { PODEX_BODY, PODEX_TITLE } from "./proxyPodex.js";
import { proxySnippets, type ProxySnippet } from "./proxySnippets.js";

export const PROXY_PRODUCT = "openburnbar-gateway";
export const PROXY_SERVICE = "openburnbar-proxy";

export type ProxyReadyState = "ready" | "degraded" | "down";
export type ProxyMode = "standalone" | "forward";

export interface ProxyHealth {
  status: "ok";
  service: typeof PROXY_SERVICE;
  pid: number;
  port: number;
  mode: ProxyMode;
  provider: string | null;
  requireToken?: boolean;
  instance: boolean;
}

export interface ProxyStatusPayload {
  product: typeof PROXY_PRODUCT;
  listening: boolean;
  ready: ProxyReadyState;
  port: number;
  openaiUrl: string;
  anthropicUrl: string;
  localKey: typeof LOCAL_CLIPROXY_KEY | null;
  requiresPrivateToken?: boolean;
  mode: ProxyMode | null;
  provider: string | null;
  configured: boolean;
  pid?: number;
  occupied?: boolean;
  command?: string;
  commands: {
    status: string;
    stop: string;
  };
}

export interface GatewayPanelPayload extends ProxyStatusPayload {
  models: string[];
  snippets: ProxySnippet[];
  podexTitle: string;
  podexBody: string;
  installBurnBar: string;
  openBurnBar: string;
}

export function proxyMode(options: ProxyOptions): Pick<ProxyHealth, "mode" | "provider"> {
  if (options.upstream) {
    return { mode: "forward", provider: null };
  }
  return { mode: "standalone", provider: options.provider?.name ?? null };
}

export function isProxyConfigured(options: Pick<ProxyOptions, "upstream" | "provider">): boolean {
  return Boolean(options.upstream || options.provider);
}

export function statusCommands(port: number): { status: string; stop: string } {
  const portFlag = port === DEFAULT_PROXY_PORT ? "" : ` --port ${port}`;
  return {
    status: `openburnbar proxy status${portFlag}`,
    stop: `openburnbar proxy stop${portFlag}`,
  };
}

export function buildProxyStatusPayload(input: {
  port: number;
  listening: boolean;
  occupied?: boolean;
  pid?: number;
  command?: string;
  mode?: ProxyMode | null;
  provider?: string | null;
  configured?: boolean;
  requireToken?: boolean;
}): ProxyStatusPayload {
  const occupied = Boolean(input.occupied);
  const configured = Boolean(input.configured);
  let ready: ProxyReadyState = "down";
  if (input.listening) {
    ready = configured ? "ready" : "degraded";
  } else if (occupied) {
    ready = "degraded";
  }
  const payload: ProxyStatusPayload = {
    product: PROXY_PRODUCT,
    listening: input.listening,
    ready,
    port: input.port,
    openaiUrl: openaiGatewayUrl(input.port),
    anthropicUrl: anthropicGatewayUrl(input.port),
    localKey: input.requireToken ? null : LOCAL_CLIPROXY_KEY,
    requiresPrivateToken: Boolean(input.requireToken),
    mode: input.mode ?? null,
    provider: input.provider ?? null,
    configured,
    commands: statusCommands(input.port),
  };
  if (input.pid !== undefined) {
    payload.pid = input.pid;
  }
  if (occupied) {
    payload.occupied = true;
  }
  if (input.command) {
    payload.command = input.command;
  }
  return payload;
}

export function buildGatewayPanelPayload(
  status: ProxyStatusPayload,
  models: string[]
): GatewayPanelPayload {
  return {
    ...status,
    models,
    snippets: proxySnippets(status.port),
    podexTitle: PODEX_TITLE,
    podexBody: PODEX_BODY,
    installBurnBar: "openburnbar app install",
    openBurnBar: "open -a OpenBurnBar",
  };
}

export function loopbackBindHint(port: number): string {
  return `http://${DEFAULT_PROXY_HOST}:${port}`;
}
