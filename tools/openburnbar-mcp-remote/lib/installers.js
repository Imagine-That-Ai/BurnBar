const command = "openburnbar-mcp-remote";
export function installer(kind) {
    const json = JSON.stringify({
        mcpServers: {
            openburnbar: {
                command,
                args: ["mcp", "serve"],
                env: {
                    OPENBURNBAR_MCP_ENDPOINT: "https://mcp.openburnbar.com/mcp"
                }
            }
        }
    }, null, 2);
    switch (kind) {
        case "codex":
            return `codex mcp add openburnbar -- ${command} mcp serve`;
        case "claude":
            return `claude mcp add openburnbar -- ${command} mcp serve`;
        case "droid":
            return json;
        case "kimi":
            return json;
        case "forge":
            return json;
        case "generic":
            return json;
    }
}
