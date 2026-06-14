type CloudSearchPostingKind = "token" | "semantic";

interface CloudSearchPostingSource {
  uid: string;
  chunkID: string;
  documentID: string;
  sourceKind: string;
  sourceID: string;
  provider?: string;
  ordinal: number;
  bodyHash: string;
  bodyHashVersion?: number;
  storagePath: string;
  sealedSnippet: unknown;
  indexVersion: number;
  commitID: string;
  updatedAt: unknown;
}

interface CloudSearchPostingEdge {
  edgeID: string;
  data: Record<string, unknown>;
}

const MAX_TOKEN_POSTING_EDGES_PER_CHUNK = 96;

function uniqueHashes(hashes: string[]): string[] {
  return Array.from(new Set(hashes));
}

export function buildCloudSearchPostingEdges(params: {
  source: CloudSearchPostingSource;
  tokenHashes: string[];
  semanticHashes: string[];
}): CloudSearchPostingEdge[] {
  const edges: CloudSearchPostingEdge[] = [];

  const emit = (kind: CloudSearchPostingKind, hashes: string[]) => {
    const boundedHashes =
      kind === "token" ? uniqueHashes(hashes).slice(0, MAX_TOKEN_POSTING_EDGES_PER_CHUNK) : uniqueHashes(hashes);
    for (const hash of boundedHashes) {
      const postingKey = `${kind}_${hash}`;
      const edgeID = `${postingKey}_${params.source.chunkID}`;
      edges.push({
        edgeID,
        data: {
          uid: params.source.uid,
          postingKey,
          edgeID,
          kind,
          hash,
          chunkID: params.source.chunkID,
          documentID: params.source.documentID,
          sourceKind: params.source.sourceKind,
          sourceID: params.source.sourceID,
          provider: params.source.provider,
          ordinal: params.source.ordinal,
          bodyHash: params.source.bodyHash,
          bodyHashVersion: params.source.bodyHashVersion,
          storagePath: params.source.storagePath,
          sealedSnippet: params.source.sealedSnippet,
          updatedAt: params.source.updatedAt,
          indexVersion: params.source.indexVersion,
          commitID: params.source.commitID,
          schemaVersion: 1,
        },
      });
    }
  };

  emit("token", params.tokenHashes);
  emit("semantic", params.semanticHashes);
  return edges;
}

export function cloudSearchFallbackHashes(requestedHashes: string[], postingMatchedHashes: Iterable<string>): string[] {
  const matched = new Set(postingMatchedHashes);
  return uniqueHashes(requestedHashes).filter((hash) => !matched.has(hash));
}
