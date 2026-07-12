export function validateArchitectureShardSet({ manifest, shards, version, commit }) {
  const failures = [];
  const architectures = new Set();
  const artifactKeys = new Set();
  const expectedKeys = new Set();

  for (const architecture of manifest.supportedArchitectures ?? []) {
    for (const type of manifest.requiredArtifacts ?? []) {
      expectedKeys.add(`${type}:${architecture}`);
    }
  }

  for (const shard of shards ?? []) {
    const architecture = shard?.architecture;
    if (shard?.schemaVersion !== 1) failures.push(`shard ${architecture ?? '<missing>'} schemaVersion must be 1`);
    if (!(manifest.supportedArchitectures ?? []).includes(architecture)) {
      failures.push(`unsupported shard architecture: ${architecture ?? '<missing>'}`);
      continue;
    }
    if (architectures.has(architecture)) failures.push(`duplicate architecture shard: ${architecture}`);
    architectures.add(architecture);
    if (shard.version !== version) failures.push(`shard ${architecture} version does not match ${version}`);
    if (shard.git?.commit !== commit) failures.push(`shard ${architecture} commit does not match ${commit}`);
    if (shard.git?.dirty === true) failures.push(`shard ${architecture} was built from a dirty checkout`);
    if ((shard.blockers ?? []).length > 0) failures.push(`shard ${architecture} contains build blockers`);

    for (const artifact of shard.artifacts ?? []) {
      const key = `${artifact?.type}:${artifact?.architecture}`;
      if (artifact?.architecture !== architecture) failures.push(`shard ${architecture} contains cross-architecture artifact ${key}`);
      if (!expectedKeys.has(key)) failures.push(`unexpected shard artifact: ${key}`);
      if (artifactKeys.has(key)) failures.push(`duplicate shard artifact: ${key}`);
      artifactKeys.add(key);
    }
  }

  for (const architecture of manifest.supportedArchitectures ?? []) {
    if (!architectures.has(architecture)) failures.push(`missing architecture shard: ${architecture}`);
  }
  for (const key of expectedKeys) {
    if (!artifactKeys.has(key)) failures.push(`missing required shard artifact: ${key}`);
  }
  if (artifactKeys.size !== expectedKeys.size) failures.push('shard artifact set does not exactly cover the manifest matrix');

  return failures;
}
