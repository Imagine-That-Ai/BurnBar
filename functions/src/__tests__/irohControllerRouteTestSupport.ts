import type { KeyObject } from "node:crypto";

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

export function rawEd25519PublicKey(publicKey: KeyObject): Buffer {
  return publicKey.export({ format: "der", type: "spki" }).subarray(-32);
}

export function base32NoPad(raw: Buffer): string {
  let accumulator = 0;
  let bitCount = 0;
  let encoded = "";
  for (const byte of raw) {
    accumulator = (accumulator << 8) | byte;
    bitCount += 8;
    while (bitCount >= 5) {
      bitCount -= 5;
      encoded += BASE32_ALPHABET[(accumulator >> bitCount) & 31];
      accumulator &= (1 << bitCount) - 1;
    }
  }
  if (bitCount > 0) encoded += BASE32_ALPHABET[(accumulator << (5 - bitCount)) & 31];
  return encoded;
}

export function callableRunner(callable: unknown): (request: unknown) => Promise<unknown> {
  const run =
    callable && (typeof callable === "object" || typeof callable === "function")
      ? Reflect.get(callable, "run")
      : undefined;
  if (typeof run !== "function") throw new Error("callable test target is missing run()");
  return (request: unknown) => run.call(callable, request);
}
