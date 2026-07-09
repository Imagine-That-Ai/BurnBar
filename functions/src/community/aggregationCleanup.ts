import type { CommunityFirestore } from "./firestoreTypes.js";

const MAX_CLEANUP_BATCH_WRITES = 400;

function isStaleLeaderboardDoc(data: unknown, runStartedAt: Date): boolean {
  if (typeof data !== "object" || data === null || Array.isArray(data)) return true;
  const updatedAt = Reflect.get(data, "updatedAt");
  const parsedUpdatedAt = typeof updatedAt === "string" ? Date.parse(updatedAt) : Number.NaN;
  return !Number.isFinite(parsedUpdatedAt) || parsedUpdatedAt < runStartedAt.getTime();
}

export async function cleanupStaleLeaderboards(
  db: CommunityFirestore,
  activeDocPaths: Set<string>,
  runStartedAt: Date,
): Promise<number> {
  const snapshot = await db.collection("community_leaderboards").get();
  let batch = db.batch();
  let pending = 0;
  let deleted = 0;

  const commitPending = async () => {
    if (pending === 0) return;
    await batch.commit();
    batch = db.batch();
    pending = 0;
  };

  for (const doc of snapshot.docs) {
    if (activeDocPaths.has(doc.ref.path) || !isStaleLeaderboardDoc(doc.data(), runStartedAt)) continue;
    batch.delete(doc.ref);
    pending++;
    deleted++;
    if (pending >= MAX_CLEANUP_BATCH_WRITES) await commitPending();
  }

  await commitPending();
  return deleted;
}
