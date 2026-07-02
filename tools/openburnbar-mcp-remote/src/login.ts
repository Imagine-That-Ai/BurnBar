import {
  createDecipheriv,
  createECDH,
  createHash,
  randomBytes,
} from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { userInfo, hostname } from "node:os";
import { writeAccessToken, writeRefreshToken } from "./oauth.js";
import { readVaultKey } from "./vaultStore.js";
import { DEFAULT_ENDPOINT, isLoopbackHost, validatedMcpEndpoint } from "./shim.js";

const execFileAsync = promisify(execFile);

/**
 * Only permit auto-launching URLs the OS should treat as ordinary browser
 * navigation: https anywhere, or http on loopback for local development. This
 * blocks a semi-trusted server from steering `open`/`xdg-open` at arbitrary
 * registered URI-scheme or file:// handlers on the victim host.
 */
export function isSafeBrowserUrl(raw: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    return false;
  }
  if (parsed.protocol === "https:") {
    return true;
  }
  if (parsed.protocol === "http:" && isLoopbackHost(parsed.hostname)) {
    return true;
  }
  return false;
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

const SEALING_ALGORITHM = "p256-ecdh-aes-256-gcm-v1";
const SEALING_CONTEXT = "OpenBurnBar CLI link credential delivery v1";

type CliLinkCredentialEnvelope = {
  algorithm: typeof SEALING_ALGORITHM;
  ephemeralPublicKeyBase64: string;
  ivBase64: string;
  ciphertextBase64: string;
  authTagBase64: string;
  aad: string;
};

type CliLinkCredentials = {
  accessToken: string;
  refreshToken?: string;
};

function credentialDeliveryKey(secret: Buffer): Buffer {
  return createHash("sha256")
    .update(SEALING_CONTEXT)
    .update("\0")
    .update(secret)
    .digest();
}

function openCredentialEnvelope(
  envelope: CliLinkCredentialEnvelope,
  deliveryKey: ReturnType<typeof createECDH>,
): CliLinkCredentials {
  if (envelope.algorithm !== SEALING_ALGORITHM) {
    throw new Error("Unsupported CLI credential delivery envelope.");
  }
  const sharedSecret = deliveryKey.computeSecret(
    Buffer.from(envelope.ephemeralPublicKeyBase64, "base64"),
  );
  const key = credentialDeliveryKey(sharedSecret);
  const decipher = createDecipheriv(
    "aes-256-gcm",
    key,
    Buffer.from(envelope.ivBase64, "base64"),
  );
  decipher.setAAD(Buffer.from(envelope.aad, "utf8"));
  decipher.setAuthTag(Buffer.from(envelope.authTagBase64, "base64"));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertextBase64, "base64")),
    decipher.final(),
  ]);
  const decoded = JSON.parse(
    plaintext.toString("utf8"),
  ) as Partial<CliLinkCredentials>;
  if (!decoded.accessToken || typeof decoded.accessToken !== "string") {
    throw new Error(
      "CLI credential delivery envelope did not contain an access token.",
    );
  }
  return {
    accessToken: decoded.accessToken,
    refreshToken:
      typeof decoded.refreshToken === "string"
        ? decoded.refreshToken
        : undefined,
  };
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

export async function runLoginFlow(): Promise<void> {
  const rawEndpoint = process.env.OPENBURNBAR_MCP_ENDPOINT ?? DEFAULT_ENDPOINT;
  // Route the device-link endpoint through the same trust gate as shim.ts /
  // resume.ts so the flow only talks to mcp.burnbar.ai (or an explicitly
  // allowed custom/loopback host), never an attacker-supplied server.
  const mcpEndpoint = validatedMcpEndpoint(rawEndpoint).href;

  let startUrl = "";
  let pollUrl = "";
  if (mcpEndpoint.includes("/us-central1/")) {
    const base = mcpEndpoint.substring(0, mcpEndpoint.indexOf("/mcp"));
    startUrl = `${base}/startCliLink`;
    pollUrl = `${base}/pollCliLink`;
  } else {
    const base = mcpEndpoint.replace(/\/mcp$/, "");
    startUrl = `${base}/api/cli-link/start`;
    pollUrl = `${base}/api/cli-link/poll`;
  }

  let displayName = "CLI Session";
  try {
    const uInfo = userInfo();
    displayName = `${uInfo.username}@${hostname()}`;
  } catch {
    // Fallback if unable to read user info
  }

  const deviceSecret = randomBytes(32).toString("hex");
  const deviceSecretHash = sha256(deviceSecret);
  const deliveryKey = createECDH("prime256v1");
  deliveryKey.generateKeys();

  console.log("Initiating CLI link flow...");

  const startResponse = await fetch(startUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      clientType: "cli",
      displayName,
      deviceSecretHash,
      credentialDelivery: {
        algorithm: SEALING_ALGORITHM,
        publicKeyBase64: deliveryKey.getPublicKey("base64", "uncompressed"),
      },
    }),
  });

  if (!startResponse.ok) {
    throw new Error(
      `Failed to start link flow: ${startResponse.status} ${startResponse.statusText}\n${await startResponse.text()}`,
    );
  }

  const startData = (await startResponse.json()) as {
    deviceCode: string;
    userCode: string;
    verificationUriComplete: string;
    interval: number;
    expiresIn: number;
  };

  console.log(
    `\nTo link this CLI, please open the following URL in your browser:\n`,
  );
  console.log(`  ${startData.verificationUriComplete}\n`);
  console.log(`Confirm that the code matches: ${startData.userCode}\n`);

  // The verification URL is unauthenticated JSON from the (only semi-trusted)
  // server; only auto-launch it when it is a normal browser URL. Anything else
  // (custom scheme, file://, etc.) is left for the user to open deliberately.
  if (isSafeBrowserUrl(startData.verificationUriComplete)) {
    await openUrl(startData.verificationUriComplete);
  } else {
    console.log(
      "Not auto-opening the verification URL because it is not an http(s) address. Open it manually only if you trust it.\n",
    );
  }

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
          deviceSecret,
        }),
      });
      if (!pollResponse.ok) {
        continue;
      }
      const pollData = (await pollResponse.json()) as {
        status: "authorization_pending" | "approved" | "expired" | "denied";
        accessToken?: string;
        refreshToken?: string;
        credentialEnvelope?: CliLinkCredentialEnvelope;
      };
      if (
        pollData.status === "approved" &&
        (pollData.accessToken || pollData.credentialEnvelope)
      ) {
        const credentials = pollData.credentialEnvelope
          ? openCredentialEnvelope(pollData.credentialEnvelope, deliveryKey)
          : typeof pollData.accessToken === "string"
            ? {
                accessToken: pollData.accessToken,
                refreshToken: pollData.refreshToken,
              }
            : undefined;
        if (!credentials) {
          continue;
        }
        writeAccessToken(credentials.accessToken);
        // Store the durable refresh token so the shim can silently re-mint the
        // 15-minute access token instead of hard-401ing forever.
        if (credentials.refreshToken) {
          writeRefreshToken(credentials.refreshToken);
        }
        console.log(
          "✔ CLI device authorization approved. Token stored securely.",
        );
        tokenStored = true;
        break;
      } else if (pollData.status === "denied") {
        throw new Error("Authorization request was denied by the user.");
      } else if (pollData.status === "expired") {
        throw new Error("Authorization request has expired.");
      }
    } catch (err) {
      if (
        err instanceof Error &&
        (err.message.includes("denied") || err.message.includes("expired"))
      ) {
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
      console.log(
        "To complete linking manually, open the OpenBurnBar Mac App, go to Settings → Remote MCP, and click 'Link this Mac's CLI'.",
      );
    }
  } else {
    console.log("✔ Vault key is already provisioned locally.");
  }

  console.log('\n🎉 Linked successfully! Try running: obb resume "my topic"');
}
