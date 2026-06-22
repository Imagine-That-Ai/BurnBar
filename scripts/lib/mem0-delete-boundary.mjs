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
        ? Number(actualValue) === expectedValue
        : String(actualValue || "") === String(expectedValue);
    if (!equal) {
      throw new Error(`refusing to delete ${key}: remote metadata ${name} mismatch`);
    }
  }

  const remoteUserId = field(record, ["user_id", "userId"]);
  if (remoteUserId !== undefined && String(remoteUserId) !== String(userId)) {
    throw new Error(`refusing to delete ${key}: remote user_id mismatch`);
  }
  const remoteAppId = field(record, ["app_id", "appId"]);
  if (remoteAppId !== undefined && String(remoteAppId) !== String(appId)) {
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
