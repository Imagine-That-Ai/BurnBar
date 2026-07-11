import { createDecipheriv, createHash, type ECDH } from "node:crypto";
import { EventEmitter } from "node:events";

export const DELIVERY_ALGORITHM = "p256-ecdh-aes-256-gcm-v1";
export const DESKTOP_DELIVERY_ALGORITHM = "p256-ecdh-aes-256-gcm-v2";
export const REMOTE_DELIVERY_KEY_CONTEXT = "OpenBurnBar CLI link credential delivery v1";
export const DESKTOP_DELIVERY_KEY_CONTEXT = "OpenBurnBar desktop auth credential delivery v2";
export const DESKTOP_FLOW_BINDING = "123E4567-E89B-12D3-A456-426614174000";

export class FakeRes extends EventEmitter {
  statusCode = 0;
  body: unknown;
  private headers: Record<string, string> = {};

  status(code: number): this {
    this.statusCode = code;
    return this;
  }

  json(payload: unknown): void {
    this.body = payload;
    this.emit("finish");
  }

  setHeader(name: string, value: string): void {
    this.headers[name.toLowerCase()] = value;
  }

  getHeader(name: string): string | undefined {
    return this.headers[name.toLowerCase()];
  }
}

export async function runHttpHandler(handler: unknown, req: unknown, res: unknown): Promise<void> {
  const run = Reflect.get(Object(handler), "run");
  const callable = typeof run === "function" ? run.bind(handler) : handler;
  if (typeof callable !== "function") throw new Error("Expected HTTP handler to be callable");
  await callable(req, res);
}

export function sha256Hex(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

export function decryptEnvelope(
  delivery: ECDH,
  envelope: {
    ephemeralPublicKeyBase64: string;
    ivBase64: string;
    authTagBase64: string;
    ciphertextBase64: string;
    aad: string;
  },
  context: string,
): Record<string, unknown> {
  const sharedSecret = delivery.computeSecret(Buffer.from(envelope.ephemeralPublicKeyBase64, "base64"));
  const key = createHash("sha256").update(context).update("\0").update(sharedSecret).digest();
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(envelope.ivBase64, "base64"));
  decipher.setAAD(Buffer.from(envelope.aad, "utf8"));
  decipher.setAuthTag(Buffer.from(envelope.authTagBase64, "base64"));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertextBase64, "base64")),
    decipher.final(),
  ]);
  return JSON.parse(plaintext.toString("utf8")) as Record<string, unknown>;
}
