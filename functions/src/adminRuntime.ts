/**
 * @fileoverview Firebase Admin initialization and shared Firestore/Auth singletons.
 */

import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { setGlobalOptions } from "firebase-functions/v2";

// Sentry must be initialized before any other imports that might throw.
import "./sentry.js";

import { FUNCTIONS_REGION } from "./runtimeOptions.js";

// Pin every function to the single deployment region (see
// docs/ARCHITECTURE/region-strategy.md). Set early so functions that do not
// specify a region inherit it; per-function options still pass FUNCTIONS_REGION.
setGlobalOptions({ region: FUNCTIONS_REGION });

const configuredStorageBucket =
  process.env.OPENBURNBAR_STORAGE_BUCKET || process.env.FIREBASE_STORAGE_BUCKET || undefined;

initializeApp(configuredStorageBucket ? { storageBucket: configuredStorageBucket } : undefined);

export const db = getFirestore();
export const auth = getAuth();

// Allow optional fields (e.g. identityHint, sourceDeviceID) to be set to
// `undefined` directly on writes without crashing the transaction. Firestore
// otherwise rejects the entire document, which surfaces as a generic INTERNAL
// error to the iOS connect flow.
db.settings({ ignoreUndefinedProperties: true });
