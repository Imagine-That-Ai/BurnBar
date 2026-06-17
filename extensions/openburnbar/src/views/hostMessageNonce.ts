export function buildHostMessageNonceScript(nonce: string): string {
  return `globalThis.__OPENBURNBAR_HOST_NONCE__ = ${JSON.stringify(nonce)};`;
}
