const QUERY_INSTRUCTION = "Represent this sentence for searching relevant passages: ";
const REFLECTION_COUNT = 24;
const CLOAK_SALT = new TextEncoder().encode("OpenBurnBar-Pensieve-Cloak-Salt-v1");

function bytesOf(text: string): Uint8Array { return new TextEncoder().encode(text); }
function copyBytes(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(bytes.length));
  out.set(bytes);
  return out;
}
function bufferOf(bytes: Uint8Array): ArrayBuffer { return copyBytes(bytes).buffer; }
async function hmac(keyBytes: Uint8Array, data: Uint8Array): Promise<Uint8Array<ArrayBuffer>> {
  const key = await crypto.subtle.importKey("raw", bufferOf(keyBytes), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return copyBytes(new Uint8Array(await crypto.subtle.sign("HMAC", key, bufferOf(data))));
}
function concat(...chunks: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(chunks.reduce((sum, chunk) => sum + chunk.length, 0)));
  let offset = 0;
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.length; }
  return out;
}
async function stream(input: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const prk = await hmac(CLOAK_SALT, input);
  const chunks: Uint8Array[] = [];
  let previous = new Uint8Array(new ArrayBuffer(0));
  let written = 0;
  let counter = 1;
  while (written < length) {
    previous = await hmac(prk, concat(previous, info, copyBytes(new Uint8Array([counter]))));
    chunks.push(previous);
    written += previous.length;
    counter += 1;
  }
  return concat(...chunks).subarray(0, length);
}
async function legacyEmbed(text: string, dimensions: number): Promise<number[]> {
  const accumulator = new Float64Array(dimensions);
  const tokens = (QUERY_INSTRUCTION + text).toLowerCase().split(/[^a-z0-9]+/u).filter((token) => token.length >= 2);
  for (const token of tokens) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bufferOf(bytesOf(token))));
    const index = ((digest[0] << 8) | digest[1]) % dimensions;
    accumulator[index] += (digest[2] & 1) === 0 ? 1 : -1;
  }
  const norm = Math.sqrt(accumulator.reduce((sum, value) => sum + value * value, 0));
  return Array.from(accumulator, (value) => norm === 0 ? value : value / norm);
}
async function legacyCloak(vector: number[], vaultKey: Uint8Array, modelVersion: string): Promise<number[]> {
  const output = Float64Array.from(vector);
  const bytes = await stream(
    vaultKey,
    bytesOf(`OpenBurnBar-Pensieve-Cloak-${modelVersion}-v1`),
    REFLECTION_COUNT * output.length * 8 + 64,
  );
  let offset = 0;
  const uniform = (): number => {
    const value = (bytes[offset] * 0x1000000 + ((bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3])) >>> 0;
    offset += 4;
    return (value + 0.5) / 4294967296;
  };
  for (let reflectionIndex = 0; reflectionIndex < REFLECTION_COUNT; reflectionIndex += 1) {
    const reflection = new Float64Array(output.length);
    let normSquared = 0;
    for (let index = 0; index < output.length; index += 1) {
      const gaussian = Math.sqrt(-2 * Math.log(uniform())) * Math.cos(2 * Math.PI * uniform());
      reflection[index] = gaussian;
      normSquared += gaussian * gaussian;
    }
    const norm = Math.sqrt(normSquared);
    if (norm === 0) reflection[0] = 1;
    else for (let index = 0; index < output.length; index += 1) reflection[index] /= norm;
    let dot = 0;
    for (let index = 0; index < output.length; index += 1) dot += reflection[index] * output[index];
    for (let index = 0; index < output.length; index += 1) output[index] -= 2 * dot * reflection[index];
  }
  return Array.from(output);
}
export async function legacyEmbedAndCloakQuery(
  text: string,
  vaultKey: Uint8Array,
  dimensions: number,
  modelVersion: string,
): Promise<number[]> {
  return legacyCloak(await legacyEmbed(text, dimensions), vaultKey, modelVersion);
}
