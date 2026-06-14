/**
 * @fileoverview Passkey callables for the BurnBar web console.
 *
 * Registration is auth-gated so an already signed-in member can attach a
 * discoverable passkey. Assertion verification is intentionally unauthenticated
 * but App-Check-gated: the WebAuthn credential itself identifies the member,
 * the server consumes a single-use challenge, and Firebase Auth receives only a
 * custom token for the matched UID.
 */

import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";
import type {
  AuthenticationResponseJSON,
  AuthenticatorTransportFuture,
  RegistrationResponseJSON,
  WebAuthnCredential,
} from "@simplewebauthn/server";
import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { auth, db } from "../adminRuntime.js";
import { assertAppCheck, assertAuth } from "../auth.js";
import { getConfig } from "../config.js";
import { isRecord } from "../guards.js";
import { wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const RP_ID = "app.burnbar.ai";
const RP_NAME = "BurnBar";
const EXPECTED_ORIGINS = ["https://app.burnbar.ai", "https://burnbar-console.web.app", "http://localhost:3000"];
const CHALLENGE_TTL_MS = 5 * 60 * 1000;

const CALLABLE_OPTS = {
  region: FUNCTIONS_REGION,
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 40,
} as const;

interface StoredPasskeyCredential {
  credentialId: string;
  publicKey: string;
  counter: number;
  transports?: AuthenticatorTransportFuture[];
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

function now(): Timestamp {
  return Timestamp.now();
}

function copyBuffer(buffer: Buffer): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(new ArrayBuffer(buffer.length));
  bytes.set(buffer);
  return bytes;
}

function uidToBytes(uid: string): Uint8Array<ArrayBuffer> {
  return copyBuffer(Buffer.from(uid, "utf8"));
}

function toBase64URL(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function fromBase64URL(value: string): Uint8Array<ArrayBuffer> {
  return copyBuffer(Buffer.from(value, "base64url"));
}

function requireString(raw: unknown, field: string): string {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${field} is required.`);
  }
  return raw.trim();
}

function challengeExpired(createdAt: Timestamp): boolean {
  return Date.now() - createdAt.toMillis() > CHALLENGE_TTL_MS;
}

function credentialFromStored(stored: StoredPasskeyCredential): WebAuthnCredential {
  return {
    id: stored.credentialId,
    publicKey: fromBase64URL(stored.publicKey),
    counter: stored.counter,
    transports: stored.transports,
  };
}

function parseStoredPasskeyCredential(raw: unknown): StoredPasskeyCredential | undefined {
  if (!isRecord(raw)) return undefined;
  if (typeof raw.credentialId !== "string" || typeof raw.publicKey !== "string") return undefined;
  if (typeof raw.counter !== "number" || !Number.isFinite(raw.counter)) return undefined;
  if (!(raw.createdAt instanceof Timestamp) || !(raw.updatedAt instanceof Timestamp)) return undefined;
  const transports = Array.isArray(raw.transports)
    ? raw.transports.filter((item): item is AuthenticatorTransportFuture => typeof item === "string")
    : undefined;
  return {
    credentialId: raw.credentialId,
    publicKey: raw.publicKey,
    counter: raw.counter,
    transports,
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
  };
}

function requireStoredPasskeyCredential(raw: unknown): StoredPasskeyCredential {
  const parsed = parseStoredPasskeyCredential(raw);
  if (!parsed) throw new HttpsError("internal", "Passkey credential is malformed.");
  return parsed;
}

async function loadUserCredentials(uid: string): Promise<StoredPasskeyCredential[]> {
  const snap = await db.collection(`users/${uid}/passkey_credentials`).get();
  return snap.docs
    .map((doc) => parseStoredPasskeyCredential(doc.data()))
    .filter((credential): credential is StoredPasskeyCredential => credential !== undefined);
}

function isRegistrationResponseJSON(value: unknown): value is RegistrationResponseJSON {
  return (
    isRecord(value) && typeof value.id === "string" && typeof value.rawId === "string" && isRecord(value.response)
  );
}

function isAuthenticationResponseJSON(value: unknown): value is AuthenticationResponseJSON {
  return (
    isRecord(value) && typeof value.id === "string" && typeof value.rawId === "string" && isRecord(value.response)
  );
}

function requireRegistrationResponse(raw: unknown): RegistrationResponseJSON {
  if (!isRegistrationResponseJSON(raw)) {
    throw new HttpsError("invalid-argument", "response must be an object.");
  }
  return raw;
}

function requireAuthenticationResponse(raw: unknown): AuthenticationResponseJSON {
  if (!isAuthenticationResponseJSON(raw)) {
    throw new HttpsError("invalid-argument", "assertion must be an object.");
  }
  return raw;
}

export const registerPasskey = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("registerPasskey", async (request: CallableRequest) => {
    assertAuth(request);
    assertAppCheck(request);
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Firebase Auth is required.");

    const user = await auth.getUser(uid);
    const existing = await loadUserCredentials(uid);
    const options = await generateRegistrationOptions({
      rpName: RP_NAME,
      rpID: RP_ID,
      userID: uidToBytes(uid),
      userName: user.email ?? uid,
      userDisplayName: user.displayName ?? user.email ?? "BurnBar member",
      attestationType: "none",
      excludeCredentials: existing.map((credential) => ({
        id: credential.credentialId,
        transports: credential.transports,
      })),
      authenticatorSelection: {
        residentKey: "preferred",
        userVerification: "required",
      },
    });

    await db.doc(`users/${uid}/passkey_challenges/${options.challenge}`).set({
      kind: "registration",
      challenge: options.challenge,
      createdAt: now(),
      consumedAt: null,
    });

    return { ok: true, options };
  }),
);

export const verifyPasskeyRegistration = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("verifyPasskeyRegistration", async (request: CallableRequest) => {
    assertAuth(request);
    assertAppCheck(request);
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Firebase Auth is required.");

    const response = requireRegistrationResponse((request.data as { response?: unknown } | undefined)?.response);
    const challenge = requireString((request.data as { challenge?: unknown } | undefined)?.challenge, "challenge");
    const challengeRef = db.doc(`users/${uid}/passkey_challenges/${challenge}`);

    const challengeSnap = await challengeRef.get();
    const challengeData = challengeSnap.data();
    if (
      !challengeSnap.exists ||
      !challengeData ||
      challengeData.consumedAt ||
      challengeExpired(challengeData.createdAt)
    ) {
      throw new HttpsError("failed-precondition", "Passkey registration challenge expired or was already used.");
    }

    const verification = await verifyRegistrationResponse({
      response,
      expectedChallenge: challenge,
      expectedOrigin: EXPECTED_ORIGINS,
      expectedRPID: RP_ID,
      requireUserVerification: true,
    });
    if (!verification.verified || !verification.registrationInfo) {
      throw new HttpsError("permission-denied", "Passkey registration could not be verified.");
    }

    const credential = verification.registrationInfo.credential;
    await db.runTransaction(async (tx) => {
      const latest = await tx.get(challengeRef);
      const latestData = latest.data();
      if (!latest.exists || !latestData || latestData.consumedAt || challengeExpired(latestData.createdAt)) {
        throw new HttpsError("failed-precondition", "Passkey registration challenge expired or was already used.");
      }
      tx.update(challengeRef, { consumedAt: now() });
      tx.set(db.doc(`users/${uid}/passkey_credentials/${credential.id}`), {
        credentialId: credential.id,
        publicKey: toBase64URL(credential.publicKey),
        counter: credential.counter,
        transports: response.response.transports,
        credentialDeviceType: verification.registrationInfo.credentialDeviceType,
        credentialBackedUp: verification.registrationInfo.credentialBackedUp,
        createdAt: now(),
        updatedAt: now(),
      });
    });

    return { ok: true, credentialId: credential.id };
  }),
);

export const beginPasskeyAssertion = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("beginPasskeyAssertion", async (request: CallableRequest) => {
    assertAppCheck(request);
    const options = await generateAuthenticationOptions({
      rpID: RP_ID,
      userVerification: "required",
    });
    await db.doc(`passkey_assertion_challenges/${options.challenge}`).set({
      challenge: options.challenge,
      createdAt: now(),
      consumedAt: null,
    });
    return { ok: true, options };
  }),
);

export const verifyPasskeyAssertion = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("verifyPasskeyAssertion", async (request: CallableRequest) => {
    assertAppCheck(request);
    const assertion = requireAuthenticationResponse((request.data as { assertion?: unknown } | undefined)?.assertion);
    const challenge = requireString((request.data as { challenge?: unknown } | undefined)?.challenge, "challenge");
    const credentialId = assertion.id;

    const credentialSnap = await db
      .collectionGroup("passkey_credentials")
      .where("credentialId", "==", credentialId)
      .limit(1)
      .get();
    if (credentialSnap.empty) {
      throw new HttpsError("permission-denied", "Passkey is not registered.");
    }

    const credentialDoc = credentialSnap.docs[0];
    const uid = credentialDoc.ref.parent.parent?.id;
    if (!uid) throw new HttpsError("internal", "Passkey credential is not under a user namespace.");
    const stored = requireStoredPasskeyCredential(credentialDoc.data());
    const challengeRef = db.doc(`passkey_assertion_challenges/${challenge}`);

    const token = await db.runTransaction(async (tx) => {
      const challengeSnap = await tx.get(challengeRef);
      const challengeData = challengeSnap.data();
      if (
        !challengeSnap.exists ||
        !challengeData ||
        challengeData.consumedAt ||
        challengeExpired(challengeData.createdAt)
      ) {
        throw new HttpsError("failed-precondition", "Passkey assertion challenge expired or was already used.");
      }

      const verification = await verifyAuthenticationResponse({
        response: assertion,
        expectedChallenge: challenge,
        expectedOrigin: EXPECTED_ORIGINS,
        expectedRPID: RP_ID,
        credential: credentialFromStored(stored),
        requireUserVerification: true,
      });
      if (!verification.verified) {
        throw new HttpsError("permission-denied", "Passkey assertion could not be verified.");
      }

      tx.update(challengeRef, { consumedAt: now() });
      tx.update(credentialDoc.ref, {
        counter: verification.authenticationInfo.newCounter,
        updatedAt: now(),
        lastUsedAt: now(),
      });
      return auth.createCustomToken(uid);
    });

    return { ok: true, token };
  }),
);
