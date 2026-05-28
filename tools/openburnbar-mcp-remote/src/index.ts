#!/usr/bin/env node
import { doctor } from "./doctor.js";
import { installer, type ClientKind } from "./installers.js";
import { runResumeCli, type ResumeMode } from "./resume.js";
import { runStdioShim } from "./shim.js";
import { writeAccessToken } from "./oauth.js";
import { basename } from "node:path";

async function main(): Promise<void> {
  const [, , first, second, third] = process.argv;
  const invokedName = basename(process.argv[1] ?? "");
  const obbresumeBinary = invokedName === "obbresume";
  if (first === "resume" || first === "obbresume" || first === "Resume" || obbresumeBinary) {
    const asIdx = process.argv.indexOf("--as");
    const modelIdx = process.argv.indexOf("--model");
    const queryIdx = process.argv.indexOf("--query");
    const providerIdx = process.argv.indexOf("--provider");
    const projectIdx = process.argv.indexOf("--project");
    const targetHarness = optionValue("--as", asIdx);
    const targetModel = optionValue("--model", modelIdx);
    const provider = optionValue("--provider", providerIdx);
    const projectName = optionValue("--project", projectIdx);
    const explicitQuery = optionValue("--query", queryIdx);
    const positional = obbresumeBinary
      ? first && !first.startsWith("--") ? first : undefined
      : second && !second.startsWith("--") ? second : undefined;
    const obbResumeMode = obbresumeBinary || first === "obbresume" || first === "Resume";
    const query = explicitQuery ?? (obbResumeMode ? positional : undefined);
    const sessionId = first === "resume" || obbResumeMode ? positional : undefined;
    if (!sessionId && !query) {
      process.stderr.write(first === "obbresume" || first === "Resume"
        ? "error: OBB Resume requires fuzzy memory text or --query text\n"
        : "error: resume requires a session id or --query text\n");
      process.exit(2);
    }
    const mode: ResumeMode = process.argv.includes("--copy")
      ? "copy"
      : process.argv.includes("--open")
        ? "open"
        : process.argv.includes("--spawn")
          ? "spawn"
          : "print";
    process.exit(await runResumeCli({
      sessionId,
      query,
      provider,
      projectName,
      targetHarness,
      targetModel,
      mode
    }));
  }
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
  process.stdout.write("Usage: openburnbar mcp <serve|install|doctor|login> | resume <sessionId>|--query <memory> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn] | obbresume <memory> [--as <harness>] | OBB Resume <memory>\n");
}

function optionValue(name: string, index: number): string | undefined {
  if (index < 0) return undefined;
  const next = process.argv[index + 1];
  if (!next || next.startsWith("--")) {
    process.stderr.write(`error: ${name} requires a value\n`);
    process.exit(2);
  }
  return next;
}

void main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
