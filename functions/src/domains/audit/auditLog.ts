/**
 * @fileoverview Deployed audit-log callables (`getAuditLog`, `verifyAuditLog`).
 * Chain core lives in shared/auditLog.ts.
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "@openburnbar/functions-shared/config.js";
import { enforceAuthAndAppCheck } from "@openburnbar/functions-shared/auth.js";
import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { wrapCallableHandler } from "@openburnbar/functions-shared/logging.js";
import { stripUndefinedObject } from "@openburnbar/functions-shared/guards.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";
import {
  AUDIT_LOG_COLLECTION,
  readAuditHead,
  verifyAuditChain,
  type AuditEventCore,
} from "@openburnbar/functions-shared/shared/auditLog.js";
import { requireBoundedNumber } from "@openburnbar/functions-shared/shared/validators.js";

const CALLABLE_OPTS = {
  region: FUNCTIONS_REGION,
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 50,
} as const;

/**
 * getAuditLog — page the chain in ascending chain order. The cursor is the next
 * `seq` to read (opaque to clients beyond "pass it back to continue").
 */
export const getAuditLog = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("getAuditLog", async (request: CallableRequest<{ cursor?: unknown; limit?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to view your access audit timeline.");
    enforceAuthAndAppCheck(request, uid);

    const limit = requireBoundedNumber(request.data?.limit ?? 50, "limit", 1, 200);
    const cursor = request.data?.cursor == null ? 0 : requireBoundedNumber(request.data.cursor, "cursor", 0, 2 ** 50);

    const snap = await db
      .collection(`users/${uid}/${AUDIT_LOG_COLLECTION}`)
      .orderBy("seq", "asc")
      .where("seq", ">=", cursor)
      .limit(limit)
      .get();

    const events = snap.docs.map((doc) => {
      const data = doc.data();
      return {
        seq: Number(data.seq ?? 0),
        ts: typeof data.ts === "string" ? data.ts : "",
        actor: typeof data.actor === "string" ? data.actor : "",
        action: typeof data.action === "string" ? data.action : "",
        domain: typeof data.domain === "string" ? data.domain : "",
        prevHash: typeof data.prevHash === "string" ? data.prevHash : "",
        hash: typeof data.hash === "string" ? data.hash : "",
      };
    });

    const nextCursor = snap.size === limit ? events[events.length - 1].seq + 1 : undefined;
    return stripUndefinedObject({ ok: true, events, nextCursor });
  }),
);
export const verifyAuditLog = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("verifyAuditLog", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to verify your access audit timeline.");
    enforceAuthAndAppCheck(request, uid);

    const events: Array<AuditEventCore & { hash: string }> = [];
    let cursor = 0;
    const pageSize = 500;

    for (;;) {
      const snap = await db
        .collection(`users/${uid}/${AUDIT_LOG_COLLECTION}`)
        .orderBy("seq", "asc")
        .where("seq", ">=", cursor)
        .limit(pageSize)
        .get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        const data = doc.data();
        events.push({
          seq: Number(data.seq),
          ts: typeof data.ts === "string" ? data.ts : "",
          actor: typeof data.actor === "string" ? data.actor : "",
          action: typeof data.action === "string" ? data.action : "",
          domain: typeof data.domain === "string" ? data.domain : "",
          prevHash: typeof data.prevHash === "string" ? data.prevHash : "",
          hash: typeof data.hash === "string" ? data.hash : "",
        });
      }

      if (snap.size < pageSize) break;
      cursor = events.length;
    }

    const head = await readAuditHead(uid);
    const result = verifyAuditChain(events, head);
    if (result.valid) {
      return { ok: true, valid: true, verifiedMaxSeq: result.verifiedMaxSeq };
    }
    return { ok: true, valid: false, brokenAt: result.brokenAt, reason: result.reason };
  }),
);
