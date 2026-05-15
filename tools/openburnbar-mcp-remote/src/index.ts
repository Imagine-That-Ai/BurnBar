#!/usr/bin/env node
import { doctor } from "./doctor.js";
import { installer, type ClientKind } from "./installers.js";
import { runStdioShim } from "./shim.js";
import { writeAccessToken } from "./oauth.js";

async function main(): Promise<void> {
  const [, , first, second, third] = process.argv;
  if (first === "mcp" && second === "serve") {
    await runStdioShim();
    return;
  }
  if (first === "mcp" && second === "install") {
    process.stdout.write(`${installer((third ?? "generic") as ClientKind)}\n`);
    return;
  }
  if (first === "mcp" && second === "doctor") {
    process.exit(await doctor());
  }
  if (first === "mcp" && second === "login" && third) {
    writeAccessToken(third);
    process.stdout.write("OpenBurnBar MCP token stored.\n");
    return;
  }
  process.stdout.write("Usage: openburnbar mcp <serve|install|doctor|login>\n");
}

void main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
