import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmSync } from "node:fs";

import { afterEach, describe, expect, it } from "vitest";

import { BurnBarDaemonClient } from "../src/daemon/client";

const socketsToClean = new Set<string>();

afterEach(() => {
  for (const socketPath of socketsToClean) {
    rmSync(socketPath, { force: true });
  }
  socketsToClean.clear();
});

describe("BurnBarDaemonClient", () => {
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

    const client = new BurnBarDaemonClient({ socketPath });
    await expect(client.health()).resolves.toMatchObject({
      ok: true,
      daemonVersion: "0.1.0",
      socketPath
    });

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

    const client = new BurnBarDaemonClient({ socketPath });
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
              message: "Unsupported BurnBar RPC method."
            }
          }) + "\n"
        );
      });
    });

    await listen(server, socketPath);

    const client = new BurnBarDaemonClient({ socketPath });
    await expect(client.health()).rejects.toThrow("Unsupported BurnBar RPC method.");

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

    const client = new BurnBarDaemonClient({ socketPath });
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

    const client = new BurnBarDaemonClient({ socketPath });
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
  const socketPath = join(tmpdir(), `burnbar-${process.pid}-${Date.now()}-${name}.sock`);
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
