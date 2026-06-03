const EMBEDDING_DIM = 384;
const EMBEDDING_MODEL_VERSION = "hashing-bow-v1";
const BGE_QUERY_INSTRUCTION = "Represent this sentence for searching relevant passages: ";
const CLOAK_REFLECTIONS = 24;
const CLOAK_SALT = new TextEncoder().encode("OpenBurnBar-Pensieve-Cloak-Salt-v1");

function bytesOf(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

function copyBytes(bytes: Uint8Array): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(bytes.length));
  out.set(bytes);
  return out;
}

function bufferOf(bytes: Uint8Array): ArrayBuffer {
  return copyBytes(bytes).buffer;
}

async function hmacSha256(keyBytes: Uint8Array, data: Uint8Array): Promise<Uint8Array<ArrayBuffer>> {
  const key = await crypto.subtle.importKey("raw", bufferOf(keyBytes), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return copyBytes(new Uint8Array(await crypto.subtle.sign("HMAC", key, bufferOf(data))));
}

function concat(...chunks: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(new ArrayBuffer(chunks.reduce((sum, chunk) => sum + chunk.length, 0)));
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

async function hkdfSha256(input: Uint8Array, salt: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const prk = await hmacSha256(salt.length > 0 ? salt : new Uint8Array(32), input);
  const chunks: Uint8Array[] = [];
  let previous = new Uint8Array(new ArrayBuffer(0));
  let written = 0;
  let counter = 1;
  while (written < length) {
    previous = await hmacSha256(prk, concat(previous, info, copyBytes(new Uint8Array([counter]))));
    chunks.push(previous);
    written += previous.length;
    counter += 1;
  }
  return concat(...chunks).subarray(0, length);
}

function l2normalize(vector: ArrayLike<number>): Float64Array {
  let normSq = 0;
  for (let i = 0; i < vector.length; i += 1) normSq += vector[i] * vector[i];
  const norm = Math.sqrt(normSq) || 1;
  const out = new Float64Array(vector.length);
  for (let i = 0; i < vector.length; i += 1) out[i] = vector[i] / norm;
  return out;
}

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bufferOf(bytesOf(text))));
}

function readUInt32BE(bytes: Uint8Array, offset: number): number {
  return (
    bytes[offset] * 0x1000000 +
    ((bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3])
  ) >>> 0;
}

function makeUniformStream(bytes: Uint8Array): () => number {
  let offset = 0;
  return () => {
    if (offset + 4 > bytes.length) offset = 0;
    const u = readUInt32BE(bytes, offset);
    offset += 4;
    return (u + 0.5) / 4294967296;
  };
}

function nextGaussian(uniform: () => number): number {
  const u1 = uniform();
  const u2 = uniform();
  return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

async function deriveReflections(vaultKey: Uint8Array, modelVersion: string, dim: number): Promise<Float64Array[]> {
  const info = bytesOf(`OpenBurnBar-Pensieve-Cloak-${modelVersion}-v1`);
  const byteLen = CLOAK_REFLECTIONS * dim * 2 * 4 + 64;
  const keystream = await hkdfSha256(vaultKey, CLOAK_SALT, info, byteLen);
  const uniform = makeUniformStream(keystream);
  const vectors: Float64Array[] = [];
  for (let r = 0; r < CLOAK_REFLECTIONS; r += 1) {
    const v = new Float64Array(dim);
    let normSq = 0;
    for (let i = 0; i < dim; i += 1) {
      const g = nextGaussian(uniform);
      v[i] = g;
      normSq += g * g;
    }
    const norm = Math.sqrt(normSq);
    if (norm === 0) v[0] = 1;
    else for (let i = 0; i < dim; i += 1) v[i] /= norm;
    vectors.push(v);
  }
  return vectors;
}

async function hashEmbedding(text: string): Promise<number[]> {
  const acc = new Float64Array(EMBEDDING_DIM);
  const tokens = (BGE_QUERY_INSTRUCTION + text).toLowerCase().split(/[^a-z0-9]+/u).filter((t) => t.length >= 2);
  for (const token of tokens) {
    const digest = await sha256(token);
    const index = ((digest[0] << 8) | digest[1]) % EMBEDDING_DIM;
    const sign = (digest[2] & 1) === 0 ? 1 : -1;
    acc[index] += sign;
  }
  return Array.from(l2normalize(acc));
}

async function cloakVector(vector: ArrayLike<number>, vaultKey: Uint8Array, modelVersion: string): Promise<number[]> {
  const x = Float64Array.from(vector);
  const reflections = await deriveReflections(vaultKey, modelVersion, x.length);
  for (const v of reflections) {
    let dot = 0;
    for (let i = 0; i < x.length; i += 1) dot += v[i] * x[i];
    const c = 2 * dot;
    for (let i = 0; i < x.length; i += 1) x[i] -= c * v[i];
  }
  return Array.from(x);
}

export async function embedAndCloakQuery(text: string, vaultKey: Uint8Array) {
  const raw = await hashEmbedding(text);
  return {
    embeddingModelVersion: EMBEDDING_MODEL_VERSION,
    queryVector: await cloakVector(raw, vaultKey, EMBEDDING_MODEL_VERSION),
  };
}
