import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  SIGNAL_AT_REST_ENCRYPTION,
  SIGNAL_BINDING_AAD_PREFIX,
  SIGNAL_ENVELOPE_FORMAT_VERSION,
  SIGNAL_RELAY_KEY_VERSION,
  SIGNAL_TRANSPORT_ENCRYPTION,
  bindingToAAD,
  sanitizeSignalEnvelope,
  sanitizeSignalEnvelopeForExport,
  type SignalBinding,
} from "./index.js";

interface BindingAADVector {
  name: string;
  binding: SignalBinding;
  expectedAAD: string;
}

interface BindingAADFixture {
  prefix: string;
  vectors: BindingAADVector[];
}

// The fixture lives at <package>/fixtures/binding-aad-vectors.json. The compiled
// test runs from lib/, so resolve relative to this module then walk up to the
// package root. This is the SAME byte-parity fixture the Swift suite consumes.
const fixtureUrl = new URL("../fixtures/binding-aad-vectors.json", import.meta.url);
const bindingAADFixture = JSON.parse(readFileSync(fileURLToPath(fixtureUrl), "utf8")) as BindingAADFixture;

function transportEnvelope() {
  return {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "transport",
    relayKeyVersion: SIGNAL_RELAY_KEY_VERSION,
    relayEncryption: SIGNAL_TRANSPORT_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "Y2lwaGVydGV4dA==",
      payloadAADLabel: "hermes-gateway:event",
      schemaVersion: 1,
    },
    keyDelivery: {
      scheme: SIGNAL_TRANSPORT_ENCRYPTION,
      signalMessageType: 3,
      signalMessageB64: "c2lnbmFsLW1lc3NhZ2U=",
      senderIdentityKeyId: "agent-device",
      ratchetEpochHint: 7,
    },
    binding: {
      uid: "uid-1",
      scope: "gateway",
      clientId: "client-1",
      slotId: "event-1",
      mode: "transport",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
  };
}

function atRestEnvelope() {
  return {
    signalEnvelopeFormatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    mode: "at-rest",
    relayEncryption: SIGNAL_AT_REST_ENCRYPTION,
    ciphertextLayer: {
      payloadCiphertextB64: "ZG9jLWNpcGhlcnRleHQ=",
      payloadAADLabel: "cloudvault:session_logs/body",
      schemaVersion: 1,
    },
    keyDelivery: {
      scheme: SIGNAL_AT_REST_ENCRYPTION,
      contentKeyLength: 32,
      wraps: [
        {
          recipientKind: "device",
          recipientIdentityKeyId: "device-1",
          recipientIdentityKeyB64: "cHVibGljLWtleQ==",
          sealedContentKeyB64: "c2VhbGVkLWtleQ==",
        },
      ],
    },
    binding: {
      uid: "uid-1",
      scope: "cloudvault",
      collection: "session_logs",
      docId: "doc-1",
      field: "body",
      mode: "at-rest",
      formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
    },
  };
}

test("sanitizes valid transport and at-rest Signal envelopes", () => {
  assert.deepEqual(sanitizeSignalEnvelope(transportEnvelope(), "transport"), transportEnvelope());
  assert.deepEqual(sanitizeSignalEnvelope(atRestEnvelope(), "at-rest"), atRestEnvelope());
});

test("rejects downgrade, mode confusion, malformed base64, and plaintext siblings", () => {
  assert.equal(sanitizeSignalEnvelope({ ...transportEnvelope(), signalEnvelopeFormatVersion: 0 }), undefined);
  assert.equal(sanitizeSignalEnvelope({ ...transportEnvelope(), relayKeyVersion: SIGNAL_RELAY_KEY_VERSION - 1 }), undefined);
  assert.equal(sanitizeSignalEnvelope({ ...transportEnvelope(), mode: "at-rest" }), undefined);
  assert.equal(
    sanitizeSignalEnvelope({
      ...transportEnvelope(),
      ciphertextLayer: { ...transportEnvelope().ciphertextLayer, payloadCiphertextB64: "no spaces allowed" },
    }),
    undefined,
  );
  for (const nonCanonicalBase64 of ["abc", "====", "YQ=", "YQ===", "c2lnbmFsLW1lc3NhZ2U"]) {
    assert.equal(
      sanitizeSignalEnvelope({
        ...transportEnvelope(),
        keyDelivery: { ...transportEnvelope().keyDelivery, signalMessageB64: nonCanonicalBase64 },
      }),
      undefined,
    );
  }

  const envelope = {
    ...transportEnvelope(),
    plaintext: "leak",
    keyDelivery: { ...transportEnvelope().keyDelivery, decryptedContentKey: "nope" },
  };
  const { out, dropped } = sanitizeSignalEnvelopeForExport("signalEnvelope", envelope);
  assert.deepEqual(out, transportEnvelope());
  assert.deepEqual(dropped, ["signalEnvelope.plaintext", "signalEnvelope.keyDelivery.decryptedContentKey"]);
});

test("sanitizeSignalEnvelopeForExport FAILS CLOSED on a signal-shaped but invalid envelope (no raw plaintext passthrough)", () => {
  // The dataExport caller routes anything with a numeric signalEnvelopeFormatVersion
  // here; a value that then fails strict validation must be REDACTED, not re-emitted
  // raw with an empty dropped[] (the prior fail-open leaked attacker plaintext).
  const polluted = {
    signalEnvelopeFormatVersion: 1,
    mode: "at-rest",
    INJECTED_PLAINTEXT: "the server must never read this",
    secret: { nested: "leak" },
  };
  const { out, dropped } = sanitizeSignalEnvelopeForExport("signalEnvelope", polluted);
  assert.deepEqual(out, {});
  assert.ok(!("INJECTED_PLAINTEXT" in (out as Record<string, unknown>)));
  assert.deepEqual(dropped.slice().sort(), [
    "signalEnvelope.INJECTED_PLAINTEXT",
    "signalEnvelope.mode",
    "signalEnvelope.secret",
    "signalEnvelope.signalEnvelopeFormatVersion",
  ]);
});

test("bindingToAAD produces the deterministic v1 canonical string for transport and at-rest bindings", () => {
  const transport = transportEnvelope().binding as SignalBinding;
  assert.equal(
    bindingToAAD(transport),
    `${SIGNAL_BINDING_AAD_PREFIX}transport|gateway|uid-1|client-1||||event-1|1`,
  );

  const atRest = atRestEnvelope().binding as SignalBinding;
  assert.equal(
    bindingToAAD(atRest),
    `${SIGNAL_BINDING_AAD_PREFIX}at-rest|cloudvault|uid-1||session_logs|doc-1|body||1`,
  );

  // Deterministic: the same binding serializes to the same string every call.
  assert.equal(bindingToAAD(transport), bindingToAAD(transport));
});

test("bindingToAAD keeps absent-optional positions stable as empty segments", () => {
  // Gateway binding with NO optionals beyond the required gateway ones, versus a
  // fully populated binding: the segment COUNT and pipe positions are identical;
  // only the absent optionals differ (empty vs filled), so a transport binding
  // can never be confused with an at-rest one under a shared AAD.
  const minimal: SignalBinding = {
    uid: "u",
    scope: "gateway",
    mode: "transport",
    formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
  };
  assert.equal(bindingToAAD(minimal), `${SIGNAL_BINDING_AAD_PREFIX}transport|gateway|u||||||1`);

  const full: SignalBinding = {
    uid: "u",
    scope: "cloudvault",
    clientId: "c",
    collection: "col",
    docId: "d",
    field: "f",
    slotId: "s",
    mode: "at-rest",
    formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
  };
  assert.equal(bindingToAAD(full), `${SIGNAL_BINDING_AAD_PREFIX}at-rest|cloudvault|u|c|col|d|f|s|1`);

  // Same number of '|' separators regardless of which optionals are present:
  // prefix contributes one trailing '|', then 8 join separators between 9 fields.
  const pipeCount = (s: string) => s.split("|").length - 1;
  assert.equal(pipeCount(bindingToAAD(minimal)), pipeCount(bindingToAAD(full)));
});

test("bindingToAAD throws fail-closed on a pipe- or CRLF-injected segment", () => {
  for (const injected of ["a|b", "line\r", "line\n", "x|\n"]) {
    assert.throws(
      () =>
        bindingToAAD({
          uid: injected,
          scope: "gateway",
          mode: "transport",
          formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
        }),
      /reserved '\|' or CR\/LF/,
      `injection of ${JSON.stringify(injected)} must throw`,
    );
  }
  // Injection in an OPTIONAL segment is rejected too (not silently dropped).
  assert.throws(
    () =>
      bindingToAAD({
        uid: "u",
        scope: "cloudvault",
        collection: "col|evil",
        docId: "d",
        field: "f",
        mode: "at-rest",
        formatVersion: SIGNAL_ENVELOPE_FORMAT_VERSION,
      }),
    /reserved '\|' or CR\/LF/,
  );
});

test("bindingToAAD matches the shared cross-language fixture byte-for-byte", () => {
  assert.equal(bindingAADFixture.prefix, SIGNAL_BINDING_AAD_PREFIX);
  assert.ok(bindingAADFixture.vectors.length >= 4, "fixture must cover the documented vectors");
  for (const vector of bindingAADFixture.vectors) {
    assert.equal(
      bindingToAAD(vector.binding),
      vector.expectedAAD,
      `${vector.name}: TS output must equal the vendored expectedAAD`,
    );
  }
});

test("bindingToAAD normalizes NFD to the same bytes as NFC (cross-platform Unicode parity)", () => {
  // The shared fixture stores 'é' as the PRECOMPOSED single code point U+00E9
  // (NFC). The decomposed form 'e' + U+0301 (COMBINING ACUTE ACCENT) is a
  // different byte sequence for the same logical string. Without NFC
  // normalization the two would yield divergent AAD and fail to open each
  // other's ciphertext across Node/Swift. Prove they collapse to one AAD.
  const nfcVector = bindingAADFixture.vectors.find((v) => v.name === "non-ascii-nfc-uid");
  assert.ok(nfcVector, "fixture must include the non-ascii-nfc-uid vector");

  const nfcUid = nfcVector.binding.uid;
  assert.equal(nfcUid.normalize("NFC"), nfcUid, "fixture uid must be stored in NFC");
  const nfdUid = nfcUid.normalize("NFD");
  assert.notEqual(nfdUid, nfcUid, "NFD and NFC of the fixture uid must differ at the byte level");

  const nfcBinding: SignalBinding = { ...nfcVector.binding };
  const nfdBinding: SignalBinding = { ...nfcVector.binding, uid: nfdUid };

  // The NFD-fed binding produces the SAME AAD as the NFC fixture value.
  assert.equal(bindingToAAD(nfdBinding), nfcVector.expectedAAD, "NFD uid must canonicalize to the NFC expectedAAD");
  assert.equal(bindingToAAD(nfdBinding), bindingToAAD(nfcBinding), "NFD and NFC bindings must produce identical AAD");

  // Sanity: ASCII vectors are NFC-stable, so normalization is a no-op for them.
  for (const vector of bindingAADFixture.vectors) {
    if (vector.name === "non-ascii-nfc-uid") {continue;}
    assert.equal(vector.expectedAAD.normalize("NFC"), vector.expectedAAD, `${vector.name} expectedAAD must be NFC-stable`);
  }
});
