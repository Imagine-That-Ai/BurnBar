/**
 * @fileoverview Firebase Admin initialization and shared Firestore/Auth singletons.
 */

import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";

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
