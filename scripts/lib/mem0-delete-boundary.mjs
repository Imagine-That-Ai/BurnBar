function splitManifestKey(key) {
  const hashIndex = key.lastIndexOf("#");
  if (hashIndex <= 0 || hashIndex === key.length - 1) {
    throw new Error(`invalid manifest key: ${key}`);
  }
  const sourcePath = key.slice(0, hashIndex);
  const chunkIndex = Number(key.slice(hashIndex + 1));
  if (!Number.isSafeInteger(chunkIndex) || chunkIndex < 0) {
    throw new Error(`invalid manifest chunk index: ${key}`);
  }
  return { sourcePath, chunkIndex };
}

function firstRecord(raw) {
  if (!raw) return null;
  if (Array.isArray(raw)) return raw[0] || null;
  if (raw.memory && typeof raw.memory === "object") return raw.memory;
  if (raw.result && typeof raw.result === "object") return firstRecord(raw.result);
  if (raw.results && Array.isArray(raw.results)) return firstRecord(raw.results);
  return raw;
}

function field(record, names) {
  for (const name of names) {
    if (record?.[name] !== undefined && record?.[name] !== null) return record[name];
  }
  return undefined;
}

function requiredField(record, names, label, key) {
  const value = field(record, names);
  if (value === undefined || String(value).trim() === "") {
    throw new Error(`refusing to delete ${key}: remote ${label} missing`);
  }
  return value;
}

function parseMetadataChunkIndex(value, key) {
  if (Number.isSafeInteger(value) && value >= 0) return value;
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (/^(0|[1-9]\d*)$/.test(trimmed)) {
      const parsed = Number(trimmed);
      if (Number.isSafeInteger(parsed)) return parsed;
    }
  }
  throw new Error(`refusing to delete ${key}: remote metadata chunk_index mismatch`);
}

export function assertMem0DeleteScope(rawMemory, { key, userId, appId }) {
  const record = firstRecord(rawMemory);
  const metadata = record?.metadata;
  if (!metadata || typeof metadata !== "object") {
    throw new Error(`refusing to delete ${key}: remote memory has no metadata`);
  }

  const { sourcePath, chunkIndex } = splitManifestKey(key);
  const expected = {
    source: "droid-wiki",
    source_path: sourcePath,
    chunk_index: chunkIndex,
  };
  for (const [name, expectedValue] of Object.entries(expected)) {
    const actualValue = metadata[name];
    const equal =
      name === "chunk_index"
        ? parseMetadataChunkIndex(actualValue, key) === expectedValue
        : String(actualValue || "") === String(expectedValue);
    if (!equal) {
      throw new Error(`refusing to delete ${key}: remote metadata ${name} mismatch`);
    }
  }

  const remoteUserId = requiredField(record, ["user_id", "userId"], "user_id", key);
  if (String(remoteUserId) !== String(userId)) {
    throw new Error(`refusing to delete ${key}: remote user_id mismatch`);
  }
  const remoteAppId = requiredField(record, ["app_id", "appId"], "app_id", key);
  if (String(remoteAppId) !== String(appId)) {
    throw new Error(`refusing to delete ${key}: remote app_id mismatch`);
  }
}

export async function deleteManifestMemory({ client, memoryId, key, userId, appId }) {
  if (!memoryId || typeof memoryId !== "string") {
    throw new Error(`refusing to delete ${key}: manifest entry has no memory_id`);
  }
  const remote = await client.get(memoryId);
  if (remote === null) return "missing";
  assertMem0DeleteScope(remote, { key, userId, appId });
  await client.delete(memoryId);
  return "deleted";
}
