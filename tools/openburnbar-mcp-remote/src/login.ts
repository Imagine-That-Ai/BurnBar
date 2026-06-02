import { createHash, randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { userInfo, hostname } from "node:os";
import { writeAccessToken } from "./oauth.js";
import { readVaultKey } from "./vaultStore.js";
import { DEFAULT_ENDPOINT, validatedMcpEndpoint } from "./shim.js";

const execFileAsync = promisify(execFile);
const TRUSTED_VERIFICATION_ORIGINS = new Set([
  "https://burnbar.ai",
  "https://openburnbar.com",
  "https://mcp.burnbar.ai"
]);

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

async function openUrl(url: string): Promise<void> {
  try {
    if (process.platform === "darwin") {
      await execFileAsync("open", [url]);
    } else if (process.platform === "linux") {
      await execFileAsync("xdg-open", [url]);
    }
  } catch {
    // Ignore if open fails; user can copy/paste the printed URL.
  }
}

function isLoopbackHost(hostname: string): boolean {
  const normalized = hostname.toLowerCase();
  return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1" || normalized === "[::1]";
}

function endpointOrigin(endpoint: URL): string {
  return endpoint.origin;
}

function isDefaultHostedEndpoint(endpoint: URL): boolean {
  return endpoint.protocol === "https:" && endpoint.hostname.toLowerCase() === "mcp.burnbar.ai";
}

function expectedVerificationOrigins(endpoint: URL): Set<string> {
  if (isDefaultHostedEndpoint(endpoint)) {
    return TRUSTED_VERIFICATION_ORIGINS;
  }
  return new Set([endpointOrigin(endpoint)]);
}

export function loginUrlsForEndpoint(endpoint: string): { mcpEndpoint: URL; startUrl: string; pollUrl: string } {
  const mcpEndpoint = validatedMcpEndpoint(endpoint);
  const endpointHref = mcpEndpoint.href.replace(/\/$/u, "");
  if (endpointHref.includes("/us-central1/")) {
    const mcpPathIndex = endpointHref.lastIndexOf("/mcp");
    const base = mcpPathIndex >= 0 ? endpointHref.substring(0, mcpPathIndex) : endpointHref;
    return {
      mcpEndpoint,
      startUrl: `${base}/startCliLink`,
      pollUrl: `${base}/pollCliLink`
    };
  }
  const base = endpointHref.replace(/\/mcp$/u, "");
  return {
    mcpEndpoint,
    startUrl: `${base}/api/cli-link/start`,
    pollUrl: `${base}/api/cli-link/poll`
  };
}

export function validateVerificationUriComplete(verificationUriComplete: string, endpoint: URL): URL {
  const verificationURL = new URL(verificationUriComplete);
  if (verificationURL.username || verificationURL.password) {
    throw new Error("OpenBurnBar CLI verification URL must not include URL credentials.");
  }
  if (verificationURL.protocol !== "https:" && !(verificationURL.protocol === "http:" && isLoopbackHost(verificationURL.hostname))) {
    throw new Error("OpenBurnBar CLI verification URL must use HTTPS, except loopback HTTP for local development.");
  }
  const allowedOrigins = expectedVerificationOrigins(endpoint);
  if (!allowedOrigins.has(verificationURL.origin)) {
    throw new Error(`OpenBurnBar CLI verification URL origin ${verificationURL.origin} does not match the expected BurnBar/custom auth origin.`);
  }
  return verificationURL;
}

export async function runLoginFlow(): Promise<void> {
  const { mcpEndpoint, startUrl, pollUrl } = loginUrlsForEndpoint(process.env.OPENBURNBAR_MCP_ENDPOINT ?? DEFAULT_ENDPOINT);

  let displayName = "CLI Session";
  try {
    const uInfo = userInfo();
    displayName = `${uInfo.username}@${hostname()}`;
  } catch {
    // Fallback if unable to read user info
  }

  const deviceSecret = randomBytes(32).toString("hex");
  const deviceSecretHash = sha256(deviceSecret);

  console.log("Initiating CLI link flow...");

  const startResponse = await fetch(startUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      clientType: "cli",
      displayName,
      deviceSecretHash
    })
  });

  if (!startResponse.ok) {
    throw new Error(`Failed to start link flow: ${startResponse.status} ${startResponse.statusText}\n${await startResponse.text()}`);
  }

  const startData = await startResponse.json() as {
    deviceCode: string;
    userCode: string;
    verificationUriComplete: string;
    interval: number;
    expiresIn: number;
  };
  const verificationURL = validateVerificationUriComplete(startData.verificationUriComplete, mcpEndpoint);

  console.log(`\nTo link this CLI, please open the following URL in your browser:\n`);
  console.log(`  ${verificationURL.href}\n`);
  console.log(`Confirm that the code matches: ${startData.userCode}\n`);

  await openUrl(verificationURL.href);

  const intervalMs = (startData.interval || 5) * 1000;
  const expiresAt = Date.now() + (startData.expiresIn || 600) * 1000;

  console.log("Waiting for browser authorization...");

  let tokenStored = false;
  while (Date.now() < expiresAt) {
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
    try {
      const pollResponse = await fetch(pollUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          deviceCode: startData.deviceCode,
          deviceSecret
        })
      });
      if (!pollResponse.ok) {
        continue;
      }
      const pollData = await pollResponse.json() as {
        status: "authorization_pending" | "approved" | "expired" | "denied";
        accessToken?: string;
      };
      if (pollData.status === "approved" && pollData.accessToken) {
        writeAccessToken(pollData.accessToken);
        console.log("✔ CLI device authorization approved. Token stored securely.");
        tokenStored = true;
        break;
      } else if (pollData.status === "denied") {
        throw new Error("Authorization request was denied by the user.");
      } else if (pollData.status === "expired") {
        throw new Error("Authorization request has expired.");
      }
    } catch (err) {
      if (err instanceof Error && (err.message.includes("denied") || err.message.includes("expired"))) {
        throw err;
      }
      // Ignore transient network errors
    }
  }

  if (!tokenStored) {
    throw new Error("Link flow timed out waiting for authorization.");
  }

  // Vault key synchronization
  if (!readVaultKey()) {
    console.log("\nNo vault key found locally.");
    console.log("Opening OpenBurnBar app to link your vault key...");
    await openUrl("openburnbar://link-cli");

    const pollStart = Date.now();
    let linked = false;
    console.log("Waiting for vault key sync...");
    while (Date.now() - pollStart < 30000) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      if (readVaultKey()) {
        linked = true;
        console.log("✔ Vault key linked successfully from OpenBurnBar app!");
        break;
      }
    }
    if (!linked) {
      console.log("\n⚠️  Vault key linking timed out.");
      console.log("To complete linking manually, open the OpenBurnBar Mac App, go to Settings → Remote MCP, and click 'Link this Mac's CLI'.");
    }
  } else {
    console.log("✔ Vault key is already provisioned locally.");
  }

  console.log("\n🎉 Linked successfully! Try running: obb resume \"my topic\"");
}
