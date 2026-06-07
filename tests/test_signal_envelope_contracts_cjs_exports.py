import subprocess
import textwrap
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def require_built_artifacts(*relative_paths: str) -> None:
    missing = [path for path in relative_paths if not (REPO_ROOT / path).exists()]
    if missing:
        if not (REPO_ROOT / "functions/node_modules/.bin/tsc").exists():
            subprocess.run(["npm", "ci", "--prefix", "functions"], cwd=REPO_ROOT, check=True)
        subprocess.run(["npm", "run", "build", "--prefix", "functions"], cwd=REPO_ROOT, check=True)
    still_missing = [path for path in relative_paths if not (REPO_ROOT / path).exists()]
    assert still_missing == []


def test_functions_runtime_can_require_signal_envelope_contracts() -> None:
    require_built_artifacts(
        "functions/node_modules/@openburnbar/signal-envelope-contracts",
        "functions/lib/signalAtRestWrite.js",
    )
    script = textwrap.dedent(
        """
        const assert = require("node:assert/strict");
        const contracts = require("./functions/node_modules/@openburnbar/signal-envelope-contracts");
        const writeGuard = require("./functions/lib/signalAtRestWrite.js");

        const b64 = (s) => Buffer.from(s, "utf8").toString("base64");
        const expected = {
          uid: "uid-1",
          collection: "mobile_assistant_chats",
          docId: "thread-1",
          field: "signalEnvelope",
        };
        const envelope = {
          signalEnvelopeFormatVersion: 1,
          mode: "at-rest",
          relayEncryption: "signal-hpke-identity-seal-v1",
          ciphertextLayer: {
            payloadCiphertextB64: b64("sealed-payload-bytes"),
            payloadAADLabel: "bindingToAAD-sha256:0123456789abcdef0123456789abcdef",
            schemaVersion: 1,
          },
          keyDelivery: {
            scheme: "signal-hpke-identity-seal-v1",
            contentKeyLength: 32,
            wraps: [
              {
                recipientKind: "device",
                recipientIdentityKeyId: "device-key-1",
                recipientIdentityKeyB64: b64("public-key-bytes-x"),
                sealedContentKeyB64: b64("sealed-content-key"),
              },
            ],
          },
          binding: {
            uid: "uid-1",
            scope: "cloudvault",
            collection: "mobile_assistant_chats",
            docId: "thread-1",
            field: "signalEnvelope",
            mode: "at-rest",
            formatVersion: 1,
          },
        };

        assert.equal(typeof contracts.sanitizeCloudVaultSignalEnvelope, "function");
        assert.equal(typeof contracts.bindingToAAD, "function");
        assert.equal(typeof writeGuard.validateSignalAtRestEnvelopeForWrite, "function");
        const result = writeGuard.validateSignalAtRestEnvelopeForWrite(envelope, expected);
        assert.equal(result.ok, true);
        assert.equal(
          result.aad,
          "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|uid-1||mobile_assistant_chats|thread-1|signalEnvelope||1",
        );
        assert.equal(
          writeGuard.validateSignalAtRestEnvelopeForWrite(
            { ...envelope, binding: { ...envelope.binding, docId: "wrong-thread" } },
            expected,
          ).reason,
          "binding-docid-mismatch",
        );
        """
    )

    subprocess.run(["node", "-e", script], cwd=REPO_ROOT, check=True)
