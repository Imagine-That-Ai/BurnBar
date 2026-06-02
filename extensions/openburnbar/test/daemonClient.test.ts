import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";

import { afterEach, describe, expect, it } from "vitest";

import { OpenBurnBarDaemonClient } from "../src/daemon/client";

const socketsToClean = new Set<string>();
const itOnDarwin = process.platform === "darwin" ? it : it.skip;

afterEach(() => {
  for (const socketPath of socketsToClean) {
    rmSync(socketPath, { force: true });
  }
  socketsToClean.clear();
});

describe("OpenBurnBarDaemonClient", () => {
  it("requests daemon health over the unix socket", async () => {
    const socketPath = makeSocketPath("health");
    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        expect(request.method).toBe("daemon.health");
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            result: {
              ok: true,
              daemonVersion: "0.1.0",
              protocolVersion: 1,
              socketPath
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);

    const client = new OpenBurnBarDaemonClient({ socketPath });
    await expect(client.health()).resolves.toMatchObject({
      ok: true,
      daemonVersion: "0.1.0",
      socketPath
    });

    await close(server);
  });

  it("adds daemon auth token to socket envelopes", async () => {
    const socketPath = makeSocketPath("auth-token");
    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        expect(request.method).toBe("daemon.health");
        expect(request.authToken).toBe("socket-secret");
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            result: {
              ok: true,
              daemonVersion: "0.1.0",
              protocolVersion: 1,
              socketPath
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);

    const client = new OpenBurnBarDaemonClient({ socketPath, authToken: "socket-secret" });
    await expect(client.health()).resolves.toMatchObject({
      ok: true
    });

    await close(server);
  });

  it("uses env auth tokens without scraping LaunchAgent plists", async () => {
    const socketPath = makeSocketPath("env-auth-token");
    const previous = {
      openBurnBar: process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN,
      legacy: process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN
    };
    process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN = "env-socket-secret";
    delete process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        expect(request.method).toBe("daemon.health");
        expect(request.authToken).toBe("env-socket-secret");
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            result: {
              ok: true,
              daemonVersion: "0.1.0",
              protocolVersion: 1,
              socketPath
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);
    try {
      const client = new OpenBurnBarDaemonClient({ socketPath });
      await expect(client.health()).resolves.toMatchObject({ ok: true });
    } finally {
      if (typeof previous.openBurnBar === "string") {
        process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN = previous.openBurnBar;
      } else {
        delete process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
      }
      if (typeof previous.legacy === "string") {
        process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN = previous.legacy;
      } else {
        delete process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
      }
      await close(server);
    }
  });

  itOnDarwin("uses the daemon auth token from Keychain coordinates when env tokens are absent", async () => {
    const socketPath = makeSocketPath("keychain-auth-token");
    const binDir = mkdtempSync(join(tmpdir(), "openburnbar-security-"));
    const fakeSecurity = join(binDir, "security");
    writeFileSync(
      fakeSecurity,
      [
        "#!/bin/sh",
        "if [ \"$1\" != \"find-generic-password\" ] || [ \"$2\" != \"-s\" ] || [ \"$3\" != \"test.service\" ] || [ \"$4\" != \"-a\" ] || [ \"$5\" != \"test.account\" ] || [ \"$6\" != \"-w\" ]; then",
        "  exit 64",
        "fi",
        "printf '%s\\n' 'keychain-socket-secret'"
      ].join("\n")
    );
    chmodSync(fakeSecurity, 0o700);

    const previous = {
      path: process.env.PATH,
      openBurnBarToken: process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN,
      legacyToken: process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN,
      service: process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_SERVICE,
      legacyService: process.env.BURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_SERVICE,
      account: process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_ACCOUNT,
      legacyAccount: process.env.BURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_ACCOUNT
    };
    process.env.PATH = `${binDir}:${previous.path ?? ""}`;
    delete process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
    delete process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
    process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_SERVICE = "test.service";
    delete process.env.BURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_SERVICE;
    process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_ACCOUNT = "test.account";
    delete process.env.BURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_ACCOUNT;

    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        expect(request.method).toBe("daemon.health");
        expect(request.authToken).toBe("keychain-socket-secret");
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            result: {
              ok: true,
              daemonVersion: "0.1.0",
              protocolVersion: 1,
              socketPath
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);
    try {
      const client = new OpenBurnBarDaemonClient({ socketPath });
      await expect(client.health()).resolves.toMatchObject({ ok: true });
    } finally {
      restoreEnv("PATH", previous.path);
      restoreEnv("OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN", previous.openBurnBarToken);
      restoreEnv("BURNBAR_DAEMON_SOCKET_AUTH_TOKEN", previous.legacyToken);
      restoreEnv("OPENBURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_SERVICE", previous.service);
      restoreEnv("BURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_SERVICE", previous.legacyService);
      restoreEnv("OPENBURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_ACCOUNT", previous.account);
      restoreEnv("BURNBAR_DAEMON_SOCKET_AUTH_KEYCHAIN_ACCOUNT", previous.legacyAccount);
      rmSync(binDir, { recursive: true, force: true });
      await close(server);
    }
  });

  it("rejects requests above the configured in-flight limit", async () => {
    const socketPath = makeSocketPath("backpressure");
    const server = createServer((socket) => {
      socket.on("data", () => {
        // Keep the first request open until the client timeout so the second call
        // exercises client-side back-pressure deterministically.
      });
    });

    await listen(server, socketPath);

    const client = new OpenBurnBarDaemonClient({ socketPath, timeoutMs: 50, maxInFlight: 1 });
    const first = client.health();
    await expect(client.health()).rejects.toThrow("RPCs in flight");
    await expect(first).rejects.toThrow("Timed out waiting for OpenBurnBar daemon");

    await close(server);
  });

  it("loads the catalog payload", async () => {
    const socketPath = makeSocketPath("catalog");
    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        expect(request.method).toBe("daemon.catalog");
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            result: {
              catalog: {
                schemaVersion: 1,
                providers: [
                  {
                    id: "z-ai",
                    displayName: "Z.ai",
                    baseURL: "https://api.z.ai",
                    visibility: "public",
                    capabilities: ["routing"],
                    models: [
                      {
                        id: "glm-4.6",
                        displayName: "GLM 4.6",
                        visibility: "public",
                        aliases: [],
                        pricing: {
                          inputPerMToken: 1,
                          outputPerMToken: 2,
                          cacheReadPerMToken: 0.5
                        }
                      }
                    ]
                  }
                ]
              }
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);

    const client = new OpenBurnBarDaemonClient({ socketPath });
    await expect(client.catalog()).resolves.toMatchObject({
      schemaVersion: 1,
      providers: [
        expect.objectContaining({
          id: "z-ai"
        })
      ]
    });

    await close(server);
  });

  it("surfaces rpc errors", async () => {
    const socketPath = makeSocketPath("error");
    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            error: {
              code: -32601,
              message: "Unsupported OpenBurnBar RPC method."
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);

    const client = new OpenBurnBarDaemonClient({ socketPath });
    await expect(client.health()).rejects.toThrow("Unsupported OpenBurnBar RPC method.");

    await close(server);
  });

  it("sends run.poll and workspace tool bridge RPC payloads", async () => {
    const socketPath = makeSocketPath("tool-bridge");
    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());

        if (request.method === "run.poll") {
          expect(request.params).toEqual({
            clientID: "client-a",
            sessionID: "session-a"
          });
          socket.end(
            JSON.stringify({
              id: request.id,
              protocolVersion: 1,
              result: {
                runs: [],
                approvals: [],
                pendingToolCalls: [],
                arbitration: {
                  activeClientID: "client-a",
                  attachedClientIDs: ["client-a"]
                },
                emittedAt: "2026-03-22T10:00:00.000Z"
              }
            }) + "\n"
          );
          return;
        }

        expect(request.method).toBe("workspace.executeTool");
        expect(request.params).toEqual({
          clientID: "client-a",
          sessionID: "session-a"
        });
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            result: {
              disposition: "no_pending_tool_call"
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);

    const client = new OpenBurnBarDaemonClient({ socketPath });
    await expect(
      client.pollRuns({
        clientID: "client-a",
        sessionID: "session-a"
      })
    ).resolves.toMatchObject({
      runs: [],
      pendingToolCalls: []
    });

    await expect(
      client.executeTool({
        clientID: "client-a",
        sessionID: "session-a"
      })
    ).resolves.toMatchObject({
      disposition: "no_pending_tool_call"
    });

    await close(server);
  });

  it("sends client.claimControl RPC payloads", async () => {
    const socketPath = makeSocketPath("claim-control");
    const server = createServer((socket) => {
      socket.on("data", (chunk) => {
        const request = JSON.parse(chunk.toString("utf8").trim());
        expect(request.method).toBe("client.claimControl");
        expect(request.params).toEqual({
          clientID: "client-a",
          sessionID: "session-a"
        });
        socket.end(
          JSON.stringify({
            id: request.id,
            protocolVersion: 1,
            result: {
              activeClientID: "client-a",
              attachedClientIDs: ["other-client", "client-a"],
              reason: "controller_transferred_to_requesting_client"
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);

    const client = new OpenBurnBarDaemonClient({ socketPath });
    await expect(
      client.claimControl({
        clientID: "client-a",
        sessionID: "session-a"
      })
    ).resolves.toMatchObject({
      activeClientID: "client-a",
      attachedClientIDs: ["other-client", "client-a"]
    });

    await close(server);
  });
});

function makeSocketPath(name: string): string {
  const socketPath = join(tmpdir(), `openburnbar-${process.pid}-${Date.now()}-${name}.sock`);
  socketsToClean.add(socketPath);
  return socketPath;
}

async function listen(server: ReturnType<typeof createServer>, socketPath: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
}

async function close(server: ReturnType<typeof createServer>): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

function restoreEnv(name: string, value: string | undefined): void {
  if (typeof value === "string") {
    process.env[name] = value;
  } else {
    delete process.env[name];
  }
}
