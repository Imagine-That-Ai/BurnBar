import { createHash, createHmac } from "node:crypto";

const CLOAK_SALT = Buffer.from("OpenBurnBar-Pensieve-Cloak-Salt-v1");
const CLOAK_REFLECTIONS = 24;
export const LEGACY_QUERY_INSTRUCTION = "Represent this sentence for searching relevant passages: ";

function hmacStream(input: Buffer, info: Buffer, length: number): Buffer {
  const prk = createHmac("sha256", CLOAK_SALT).update(input).digest();
  const chunks: Buffer[] = [];
  let previous = Buffer.alloc(0);
  let written = 0;
  let counter = 1;
  while (written < length) {
    previous = createHmac("sha256", prk)
      .update(previous)
      .update(info)
      .update(Buffer.from([counter]))
      .digest();
    chunks.push(previous);
    written += previous.length;
    counter += 1;
  }
  return Buffer.concat(chunks).subarray(0, length);
}

function reflections(vaultKey: Buffer, modelVersion: string, dimensions: number): Float64Array[] {
  const bytes = hmacStream(
    vaultKey,
    Buffer.from(`OpenBurnBar-Pensieve-Cloak-${modelVersion}-v1`),
    CLOAK_REFLECTIONS * dimensions * 8 + 64,
  );
  let offset = 0;
  const uniform = (): number => {
    const value = bytes.readUInt32BE(offset);
    offset += 4;
    return (value + 0.5) / 4294967296;
  };
  return Array.from({ length: CLOAK_REFLECTIONS }, () => {
    const vector = new Float64Array(dimensions);
    let normSquared = 0;
    for (let index = 0; index < dimensions; index += 1) {
      const gaussian = Math.sqrt(-2 * Math.log(uniform())) * Math.cos(2 * Math.PI * uniform());
      vector[index] = gaussian;
      normSquared += gaussian * gaussian;
    }
    const norm = Math.sqrt(normSquared);
    if (norm === 0) {
      vector[0] = 1;
    } else {
      for (let index = 0; index < dimensions; index += 1) {
        vector[index] /= norm;
      }
    }
    return vector;
  });
}

export function legacyCloakVector(
  vector: ArrayLike<number>,
  vaultKey: Buffer,
  modelVersion: string,
): Float64Array {
  const output = Float64Array.from(vector);
  for (const reflection of reflections(vaultKey, modelVersion, output.length)) {
    let dot = 0;
    for (let index = 0; index < output.length; index += 1) {
      dot += reflection[index] * output[index];
    }
    const coefficient = 2 * dot;
    for (let index = 0; index < output.length; index += 1) {
      output[index] -= coefficient * reflection[index];
    }
  }
  return output;
}

export function legacyDeterministicEmbed(text: string, dimensions: number, isQuery: boolean): number[] {
  const accumulator = new Float64Array(dimensions);
  const prepared = `${isQuery ? LEGACY_QUERY_INSTRUCTION : ""}${text}`.toLowerCase();
  for (const token of prepared.split(/[^a-z0-9]+/u).filter((value) => value.length >= 2)) {
    const digest = createHash("sha256").update(token).digest();
    const index = ((digest[0] << 8) | digest[1]) % dimensions;
    accumulator[index] += (digest[2] & 1) === 0 ? 1 : -1;
  }
  const norm = Math.sqrt(accumulator.reduce((sum, value) => sum + value * value, 0));
  return Array.from(accumulator, (value) => norm === 0 ? value : value / norm);
}
