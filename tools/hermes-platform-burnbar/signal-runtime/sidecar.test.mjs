import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import test from "node:test";

const sidecarPath = join(import.meta.dirname, "sidecar.mjs");

function start(stateDir, identityKeyId) {
  const child = spawn(process.execPath, [sidecarPath], {
    env: { ...process.env, BURNBAR_SIGNAL_STATE_DIR: stateDir, BURNBAR_SIGNAL_UID: "sidecar-test-user", BURNBAR_SIGNAL_IDENTITY_KEY_ID: identityKeyId },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let buffer = "";
  const waiters = [];
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    while (buffer.includes("\n")) {
      const index = buffer.indexOf("\n");
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      waiters.shift()?.(JSON.parse(line));
    }
  });
  return {
    child,
    request(payload) {
      return new Promise((resolve, reject) => {
        waiters.push(resolve);
        child.stdin.write(`${JSON.stringify(payload)}\n`, (error) => error && reject(error));
      });
    },
  };
}

test("official sidecar seals, opens, and survives restart", async () => {
  const aDir = await mkdtemp(join(tmpdir(), "obb-signal-sidecar-a-"));
  const bDir = await mkdtemp(join(tmpdir(), "obb-signal-sidecar-b-"));
  let a = start(aDir, "agent-a-1");
  const b = start(bDir, "phone-b-1");
  try {
    const aBundle = (await a.request({ op: "bundle" })).bundle;
    const bBundle = (await b.request({ op: "bundle" })).bundle;
    const first = await a.request({
      op: "seal",
      peerUid: "sidecar-test-user",
      peerBundle: bBundle,
      clientId: "gateway-client",
      slotId: "message",
      plaintextB64: Buffer.from(JSON.stringify({ text: "first" })).toString("base64"),
    });
    assert.equal(first.ok, true);
    const opened = await b.request({
      op: "open",
      peerUid: "sidecar-test-user",
      peerBundle: aBundle,
      signalMessageType: first.envelope.keyDelivery.signalMessageType,
      signalMessageB64: first.envelope.keyDelivery.signalMessageB64,
    });
    assert.equal(Buffer.from(opened.plaintextB64, "base64").toString(), JSON.stringify({ text: "first" }));

    a.child.kill();
    await once(a.child, "exit");
    a = start(aDir, "agent-a-1");
    const second = await a.request({
      op: "seal",
      peerUid: "sidecar-test-user",
      peerBundle: bBundle,
      clientId: "gateway-client",
      slotId: "message",
      plaintextB64: Buffer.from(JSON.stringify({ text: "after-restart" })).toString("base64"),
    });
    assert.equal(second.ok, true);
    const openedSecond = await b.request({
      op: "open",
      peerUid: "sidecar-test-user",
      peerBundle: aBundle,
      signalMessageType: second.envelope.keyDelivery.signalMessageType,
      signalMessageB64: second.envelope.keyDelivery.signalMessageB64,
    });
    assert.equal(Buffer.from(openedSecond.plaintextB64, "base64").toString(), JSON.stringify({ text: "after-restart" }));
  } finally {
    a.child.kill();
    b.child.kill();
    await Promise.allSettled([once(a.child, "exit"), once(b.child, "exit")]);
    await Promise.all([rm(aDir, { recursive: true, force: true }), rm(bDir, { recursive: true, force: true })]);
  }
});
