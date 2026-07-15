import { createHmac, hkdfSync } from "node:crypto";

const TOKEN_SEARCH_SALT = Buffer.from("OpenBurnBar-CloudSearch-Salt-v1");
const TOKEN_SEARCH_INFO = Buffer.from("OpenBurnBar-CloudSearch-TokenHash-v1");
const SEMANTIC_SEARCH_SALT = Buffer.from("OpenBurnBar-CloudSearch-Semantic-Salt-v1");
const SEMANTIC_SEARCH_INFO = Buffer.from("OpenBurnBar-CloudSearch-SemanticHash-v1");
const STOPWORDS = new Set([
  "the", "and", "for", "with", "that", "this", "from", "how", "what", "where", "when", "why",
  "are", "was", "were", "you", "your", "have", "has", "had", "into", "onto", "can", "could",
  "should", "would",
]);

function normalizedTokens(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/u)
    .filter((token) => token.length >= 2 && !STOPWORDS.has(token));
}

export function legacyCloudVaultTokenHashes(text: string, vaultKey: Uint8Array, limit: number): string[] {
  if (limit <= 0) {
    return [];
  }
  const searchKey = Buffer.from(hkdfSync("sha256", vaultKey, TOKEN_SEARCH_SALT, TOKEN_SEARCH_INFO, 32));
  try {
    const hashes: string[] = [];
    const seen = new Set<string>();
    for (const token of normalizedTokens(text)) {
      if (seen.has(token)) {
        continue;
      }
      seen.add(token);
      hashes.push(createHmac("sha256", searchKey).update(token).digest().subarray(0, 16).toString("hex"));
      if (hashes.length >= limit) {
        break;
      }
    }
    return hashes;
  } finally {
    searchKey.fill(0);
  }
}

function simpleSemanticStem(token: string): string {
  for (const suffix of ["ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s"]) {
    if (token.length > suffix.length + 3 && token.endsWith(suffix)) {
      const stem = token.slice(0, -suffix.length);
      return suffix === "ies" || suffix === "ied" ? `${stem}y` : stem;
    }
  }
  return token;
}

function semanticFeatures(tokens: string[]): Array<{ name: string; weight: number }> {
  const features: Array<{ name: string; weight: number }> = [];
  const seen = new Set<string>();
  const append = (name: string, weight: number): void => {
    if (!name || seen.has(name)) {
      return;
    }
    seen.add(name);
    features.push({ name, weight });
  };
  for (const token of tokens) {
    append(`token:${token}`, 2.4);
    const stem = simpleSemanticStem(token);
    if (stem !== token) {
      append(`stem:${stem}`, 1.8);
    }
    if (token.length >= 5) {
      append(`prefix:${token.slice(0, 5)}`, 0.8);
    }
  }
  for (let index = 0; index < tokens.length - 1; index += 1) {
    append(`bigram:${tokens[index]}_${tokens[index + 1]}`, 1.3);
  }
  return features;
}

export function legacyCloudVaultSemanticHashes(text: string, vaultKey: Uint8Array, limit: number): string[] {
  const tokens = normalizedTokens(text);
  if (tokens.length === 0 || limit <= 0) {
    return [];
  }
  const searchKey = Buffer.from(hkdfSync("sha256", vaultKey, SEMANTIC_SEARCH_SALT, SEMANTIC_SEARCH_INFO, 32));
  try {
    const accumulator = Array.from({ length: 64 }, () => 0);
    const features = semanticFeatures(tokens);
    for (const feature of features) {
      const digest = createHmac("sha256", searchKey).update(feature.name).digest();
      const index = ((digest[0] << 8) | digest[1]) % accumulator.length;
      accumulator[index] += (digest[2] & 1) === 0 ? feature.weight : -feature.weight;
    }
    const hashes: string[] = [];
    const seen = new Set<string>();
    const appendBucket = (bucket: string): void => {
      if (hashes.length >= limit) {
        return;
      }
      const hash = createHmac("sha256", searchKey).update(bucket).digest().subarray(0, 16).toString("hex");
      if (!seen.has(hash)) {
        seen.add(hash);
        hashes.push(hash);
      }
    };
    for (let band = 0; band < 8; band += 1) {
      let value = 0;
      for (let bit = 0; bit < 8; bit += 1) {
        if (accumulator[band * 8 + bit] >= 0) {
          value |= 1 << bit;
        }
      }
      appendBucket(`simhash:v1:band:${band}:${value.toString(16).padStart(2, "0")}`);
    }
    for (const feature of features.slice(0, Math.max(0, limit - hashes.length))) {
      appendBucket(`feature:v1:${feature.name}`);
    }
    return hashes;
  } finally {
    searchKey.fill(0);
  }
}
