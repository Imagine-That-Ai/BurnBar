import { createConnection } from 'node:net';
import { readFileSync, existsSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { linuxAuthTokenPath, linuxSocketPath } from './linuxPaths.js';

export type DaemonHealth = {
  ok: boolean;
  protocolVersion?: number;
  daemonVersion?: string;
  socketPath?: string;
  gatewayEnabled?: boolean | null;
  gatewayHost?: string;
  gatewayPort?: number;
  error?: string;
};

function readToken(): string | undefined {
  const path = linuxAuthTokenPath();
  if (!existsSync(path)) return undefined;
  const raw = readFileSync(path, 'utf8').trim();
  return raw || undefined;
}

export async function probeDaemonHealth(timeoutMs = 5000): Promise<DaemonHealth> {
  const socketPath = linuxSocketPath();
  const authToken = readToken();
  const envelope = {
    protocolVersion: 1,
    id: randomUUID(),
    method: 'daemon.health',
    traceId: randomUUID(),
    ...(authToken ? { authToken } : {})
  };
  const payload = JSON.stringify(envelope) + '\n';

  return new Promise((resolve) => {
    const socket = createConnection(socketPath);
    let buf = '';
    const fail = (error: string) => {
      socket.destroy();
      resolve({ ok: false, socketPath, error });
    };
    const timer = setTimeout(() => fail('Daemon health probe timed out'), timeoutMs);
    socket.on('error', (err) => {
      clearTimeout(timer);
      fail(err.message);
    });
    socket.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      const i = buf.indexOf('\n');
      if (i < 0) return;
      clearTimeout(timer);
      socket.destroy();
      try {
        const line = buf.slice(0, i).trim();
        const parsed = JSON.parse(line) as { result?: DaemonHealth; error?: { message?: string } };
        if (parsed.error?.message) {
          resolve({ ok: false, socketPath, error: parsed.error.message });
          return;
        }
        const result = parsed.result ?? { ok: false };
        resolve({ ...result, ok: result.ok !== false, socketPath });
      } catch (e) {
        fail(e instanceof Error ? e.message : 'Invalid daemon response');
      }
    });
    socket.on('connect', () => socket.write(payload, 'utf8'));
  });
}
