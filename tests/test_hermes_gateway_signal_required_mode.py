import subprocess
import textwrap
from pathlib import Path

from conftest import require_built_artifacts


ROOT = Path(__file__).resolve().parents[1]


def test_signal_required_mode_accepts_only_signal_gateway_writes() -> None:
    require_built_artifacts("functions/lib/hermesGateway.js")
    script = textwrap.dedent(
        r"""
        const assert = require("node:assert/strict");
        const gw = require("./functions/lib/hermesGateway.js");

        const relayPubkeyB64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 7)]).toString("base64");
        const senderPubkeyB64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 9)]).toString("base64");

        function signalEnvelope() {
          return {
            signalEnvelopeFormatVersion: gw.HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
            mode: "transport",
            relayKeyVersion: gw.HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
            relayEncryption: gw.HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
            ciphertextLayer: {
              payloadCiphertextB64: Buffer.from("signal-payload-ciphertext").toString("base64"),
              payloadAADLabel: "gatewayEvent",
              schemaVersion: gw.HERMES_GATEWAY_SCHEMA_VERSION,
            },
            keyDelivery: {
              scheme: gw.HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
              signalMessageType: 3,
              signalMessageB64: Buffer.from("serialized-prekey-signal-message").toString("base64"),
              senderIdentityKeyId: "agent-signal-identity",
              ratchetEpochHint: 1,
            },
            binding: {
              uid: "user_1",
              scope: "gateway",
              clientId: "client-1",
              slotId: "evt_signal_1",
              mode: "transport",
              formatVersion: gw.HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
            },
          };
        }

        function relayEnvelope() {
          return {
            payloadCiphertext: Buffer.from("ciphertext").toString("base64"),
            wrappedKey: Buffer.from("wrappedkey").toString("base64"),
            relayEncryption: gw.HERMES_GATEWAY_RELAY_ENCRYPTION,
            relayKeyVersion: 2,
            senderPublicKey: senderPubkeyB64,
          };
        }

        function ratchetEnvelope() {
          return {
            header: {
              version: gw.HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION,
              algorithm: gw.HERMES_GATEWAY_RATCHET_ALGORITHM,
              sessionID: "hgr_session-1",
              senderDeviceID: "agent-device",
              receiverDeviceID: "phone-device",
              ratchetPublicKeyBase64: relayPubkeyB64,
              previousChainLength: 0,
              messageNumber: 0,
              epoch: 1,
            },
            ciphertextBase64: Buffer.from("ratchet-ciphertext").toString("base64"),
          };
        }

        assert.throws(
          () => gw.requireProductionGatewaySignalEnvelope(signalEnvelope(), "signalEnvelope"),
          /runtime readiness gate/,
        );

        process.env[gw.HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] = "true";
        assert.equal(gw.gatewaySignalRequiredMode(), true);
        assert.deepEqual([...gw.productionGatewaySignalEnvelopeVersions()], [gw.HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL]);
        assert.deepEqual([...gw.productionGatewayRelayKeyVersions()], []);
        assert.deepEqual(gw.requireProductionGatewaySignalEnvelope(signalEnvelope(), "signalEnvelope"), signalEnvelope());
        assert.throws(
          () => gw.requireProductionGatewayRelayEnvelope(relayEnvelope(), "relayEnvelope"),
          /Signal-required gateway mode/,
        );
        assert.throws(
          () => gw.requireProductionGatewayRatchetEnvelope(ratchetEnvelope(), "ratchetEnvelope"),
          /Signal-required gateway mode/,
        );
        assert.throws(
          () => gw.sanitizeGatewayRelayEnvelopeCapabilities({
            supportsRelayEnvelopeVersions: [2, 3],
            preferredRelayEnvelopeVersion: 3,
            supportsHpkeV3: true,
          }),
          /supportsSignalEnvelope=true is required/,
        );
        assert.equal(gw.sanitizeGatewayRelayEnvelopeCapabilities({
          supportsRelayEnvelopeVersions: [2, 3],
          preferredRelayEnvelopeVersion: 3,
          supportsHpkeV3: true,
          supportsSignalEnvelope: true,
        }).supportsSignalEnvelope, true);
        """
    )

    subprocess.run(["node", "-e", script], cwd=ROOT, check=True)
