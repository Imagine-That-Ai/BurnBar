export const OPS_UPTIME_CHECKS = [
  {
    displayName: "OpenBurnBar uptime burnbar.ai",
    kind: "http",
    host: "burnbar.ai",
    path: "/",
    matcher: "BurnBar",
  },
  {
    displayName: "OpenBurnBar uptime app.burnbar.ai",
    kind: "http",
    host: "app.burnbar.ai",
    path: "/",
    matcher: "OpenBurnBar",
  },
  {
    displayName: "OpenBurnBar uptime hosted MCP",
    kind: "http",
    host: "mcp.burnbar.ai",
    path: "/readyz",
    matcher: "openburnbar-hosted-mcp",
  },
  {
    displayName: "OpenBurnBar uptime iroh hosted relay",
    kind: "tcp",
    host: "use1-1.relay.alberto8793.burnbar.iroh.link",
    port: 443,
  },
];

export function materializeOpsUptimeCheck(check, project) {
  const base = {
    displayName: check.displayName,
    monitoredResource: {
      type: "uptime_url",
      labels: {
        project_id: project,
        host: check.host,
      },
    },
    period: "60s",
    timeout: "10s",
    selectedRegions: ["USA", "EUROPE", "SOUTH_AMERICA"],
  };

  if (check.kind === "tcp") {
    return {
      ...base,
      tcpCheck: {
        port: check.port ?? 443,
      },
    };
  }

  return {
    ...base,
    httpCheck: {
      path: check.path ?? "/",
      port: 443,
      useSsl: true,
      validateSsl: true,
      requestMethod: "GET",
      acceptedResponseStatusCodes: [{ statusClass: "STATUS_CLASS_2XX" }],
    },
    contentMatchers: check.matcher ? [{ content: check.matcher, matcher: "CONTAINS_STRING" }] : [],
  };
}
