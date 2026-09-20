#!/usr/bin/env node
import { doctor } from "./doctor.js";
import { installer, type ClientKind } from "./installers.js";
import { runResumeCli, type ResumeMode } from "./resume.js";
import { runStdioShim } from "./shim.js";
import { writeAccessToken } from "./oauth.js";
import { parseAppCliOptions, runAppCommand, type AppCommand } from "./appInstall.js";
import { runProxyCli } from "./proxy.js";
import { basename } from "node:path";
import { readFileSync } from "node:fs";

const USAGE = `Usage: openburnbar proxy [--port 8320] [--host 127.0.0.1] [--token <token>] [--tray] | proxy <status|stop|wire|unwire> ... | app <install|update> [--dry-run] | mcp <serve|install|doctor|login> [token] | memory <install|run|sync> | resume <sessionId>|--query <memory> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn] | obbresume <memory> [--as <harness>] | OBB Resume <memory>

app install puts OpenBurnBar.app on disk; proxy starts the local OpenAI/Anthropic gateway on :8320; npm i never starts either.
`;
const APP_USAGE = "Usage: openburnbar app <install|update> [--dry-run] [--feed-url <https-url>] [--applications-dir <path>]\n";

function looksLikeSessionId(s: string | undefined): boolean {
  if (!s) {return false;}
  return /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(s) || /^[A-Za-z0-9_-]{16,}$/.test(s);
}

async function main(): Promise<void> {
  const [, , first, second, third] = process.argv;
  const invokedName = basename(process.argv[1] ?? "");
  const obbresumeBinary = invokedName === "obbresume";
  if (first === "--help" || first === "-h") {
    process.stdout.write(USAGE);
    return;
  }
  if (first === "proxy") {
    process.exit(await runProxyCli(process.argv.slice(3)));
  }
  if (first === "app") {
    process.exit(await runAppCli(second, process.argv.slice(4)));
  }
  if (first === "resume" || first === "obbresume" || first === "Resume" || obbresumeBinary) {
    const asIdx = process.argv.indexOf("--as");
    const modelIdx = process.argv.indexOf("--model");
    const queryIdx = process.argv.indexOf("--query");
    const sessionIdx = process.argv.indexOf("--session");
    const providerIdx = process.argv.indexOf("--provider");
    const projectIdx = process.argv.indexOf("--project");
    const targetHarness = optionValue("--as", asIdx);
    const targetModel = optionValue("--model", modelIdx);
    const provider = optionValue("--provider", providerIdx);
    const projectName = optionValue("--project", projectIdx);
    const explicitQuery = optionValue("--query", queryIdx);
    const explicitSessionId = optionValue("--session", sessionIdx);
    const positional = obbresumeBinary
      ? first && !first.startsWith("--") ? first : undefined
      : second && !second.startsWith("--") ? second : undefined;
    const obbResumeMode = obbresumeBinary || first === "obbresume" || first === "Resume";

    const sessionId = explicitSessionId ?? (
      !obbResumeMode && first === "resume" && positional && looksLikeSessionId(positional)
        ? positional
        : undefined
    );
    const query = explicitQuery ?? (
      obbResumeMode
        ? positional
        : (first === "resume" && positional && !looksLikeSessionId(positional) ? positional : undefined)
    );

    if (!sessionId && !query) {
      process.stderr.write(`Error: Resume requires a search query or a session ID.

Examples:
  obb resume "my topic"                      (Fuzzy search by topic)
  obb resume 381a1795-001c-4b62-bbbe-...     (Direct resume by UUID)
  obb resume --session <id>                  (Force resume by session ID)
  obb resume --query "topic" --as python     (Search topic and spawn using python harness)
  obb resume --query "topic" --copy          (Search topic and copy briefing to clipboard)
  obb resume --query "topic" --open          (Search topic and open briefing file)
`);
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
  if (first === "mcp" && second === "login") {
    if (third) {
      writeAccessToken(third);
      process.stdout.write("OpenBurnBar MCP token stored.\n");
      return;
    } else {
      const { runLoginFlow } = await import("./login.js");
      await runLoginFlow();
      return;
    }
  }
  if (first === "memory") {
    process.exit(await runMemoryCli(second, third));
  }
  process.stdout.write(USAGE);
}

async function runAppCli(sub: string | undefined, argv: string[]): Promise<number> {
  if (sub === "--help" || sub === "-h" || sub === "help") {
    process.stdout.write(APP_USAGE);
    return 0;
  }
  if (sub !== "install" && sub !== "update") {
    process.stderr.write(APP_USAGE);
    return 2;
  }
  try {
    return await runAppCommand(sub as AppCommand, parseAppCliOptions(argv));
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    return 2;
  }
}

async function runMemoryCli(sub: string | undefined, arg: string | undefined): Promise<number> {
  const { installMemoryHook, runMemorySync } = await import("./memoryHook.js");
  if (sub === "install") {
    const path = installMemoryHook({ command: "openburnbar memory run" });
    process.stdout.write(`Pensieve chat-memory hook installed: ${path}\n`);
    return 0;
  }
  if (sub === "run" || sub === "sync") {
    // `run` reads a transcript from --transcript <path> or stdin (the SessionEnd hook pipes it).
    const idx = process.argv.indexOf("--transcript");
    const transcript = idx >= 0 ? readFileSync(process.argv[idx + 1], "utf8") : readFileSync(0, "utf8");
    const sourceSlug = arg && !arg.startsWith("--") ? arg : "chat-memory";
    const batch = await runMemorySync({ transcript, sourceSlug });
    process.stdout.write(`Pensieve: prepared ${batch.vectors.length} net-new memory chunk(s) for ${batch.sourceSlug}.\n`);
    return 0;
  }
  process.stderr.write("Usage: openburnbar memory <install|run|sync> [sourceSlug] [--transcript <path>]\n");
  return 2;
}

function optionValue(name: string, index: number): string | undefined {
  if (index < 0) {return undefined;}
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
