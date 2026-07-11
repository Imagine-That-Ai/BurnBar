import type { Server } from "node:http";

export async function runServer(server: Server, port: number, role: "ingress" | "verifier"): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "0.0.0.0", () => resolve());
  });
  console.log(JSON.stringify({ severity: "INFO", event: "server_started", role, port }));
  const shutdown = (signal: string) => {
    console.log(JSON.stringify({ severity: "INFO", event: "server_stopping", role, signal }));
    server.close(error => process.exit(error === undefined ? 0 : 1));
  };
  process.once("SIGTERM", () => shutdown("SIGTERM"));
  process.once("SIGINT", () => shutdown("SIGINT"));
}
