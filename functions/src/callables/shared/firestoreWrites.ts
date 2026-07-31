/**
 * @fileoverview Batched Firestore write helper shared by callables and runtime
 * modules. Lives outside the `../shared.js` barrel so importers stay free of
 * the barrel's eager secret declarations (scoped staging deploys build a
 * per-target secret-param list from the module graph).
 */

import { type WriteBatch } from "firebase-admin/firestore";

import { db } from "../../adminRuntime.js";

export async function commitBatchedWrites(
  writes: Array<(batch: WriteBatch) => void>,
  maxWritesPerBatch = 450,
): Promise<void> {
  for (let start = 0; start < writes.length; start += maxWritesPerBatch) {
    const batch = db.batch();
    for (const write of writes.slice(start, start + maxWritesPerBatch)) {
      write(batch);
    }
    await batch.commit();
  }
}
