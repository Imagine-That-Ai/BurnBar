import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { generateAll, loadProtocol, screamingSnake, validateProtocol } from "./codegen.mjs";
import { checkParity, parseKotlinFrames, parseSwiftFrames } from "./parity.mjs";

const proto = validateProtocol(loadProtocol());

test("protocol.json is structurally valid", () => {
  assert.equal(proto.schemaVersion, 1);
  assert.ok(proto.frames.length >= 41, "expected at least 41 frame types");
});

test("frame ids and wire strings are unique", () => {
  assert.equal(new Set(proto.frames.map((f) => f.id)).size, proto.frames.length);
  assert.equal(new Set(proto.frames.map((f) => f.wire)).size, proto.frames.length);
});

test("every frame belongs to a declared group", () => {
  const groups = new Set(proto.groups.map((g) => g.id));
  for (const f of proto.frames) assert.ok(groups.has(f.group), `${f.id} -> unknown group ${f.group}`);
});

test("relay-accepted subset is exactly the session chat-multiplexing frames", () => {
  const relay = proto.frames.filter((f) => f.relayAccepted).map((f) => f.wire).sort();
  assert.deepEqual(relay, [
    "host.ready",
    "host.register",
    "ping",
    "pong",
    "request.cancel",
    "request.start",
    "response.chunk",
    "response.complete",
    "response.error",
  ]);
  // Security-relevant + media/control frames must NEVER be relay-accepted (iroh-only).
  for (const wire of ["remote_unlock.credential", "control.input.intent", "media.stream.frame", "signal.session.message"]) {
    const f = proto.frames.find((x) => x.wire === wire);
    assert.ok(f, `${wire} missing from canon`);
    assert.equal(f.relayAccepted, false, `${wire} must be iroh-only, never relay-accepted`);
  }
});

test("generated files on disk are up to date with protocol.json (drift gate)", () => {
  const files = generateAll(proto);
  for (const [abs, content] of Object.entries(files)) {
    const onDisk = readFileSync(abs, "utf8");
    assert.equal(onDisk, content, `${abs} is stale — regenerate with: node packages/hermes-wire-protocol/codegen.mjs`);
  }
});

test("all hand-written language surfaces match canon (parity gate)", () => {
  const errors = checkParity(proto);
  assert.deepEqual(errors, [], errors.join("\n"));
});

test("parity gate CATCHES drift (perturbed canon vs real source)", () => {
  // If canon renamed a wire string, the real Swift/Kotlin/TS surfaces would no
  // longer match — checkParity must report it (proving the gate isn't a no-op).
  const perturbed = structuredClone(proto);
  perturbed.frames[0].wire = "host.register.RENAMED";
  const errors = checkParity(perturbed);
  assert.ok(errors.length > 0, "parity gate should report drift for a perturbed canon");
  assert.ok(errors.some((e) => /Swift|Kotlin/.test(e)), `expected Swift/Kotlin drift, got: ${errors.join("; ")}`);
});

test("parity gate CATCHES a changed wire constant", () => {
  const perturbed = structuredClone(proto);
  perturbed.protocol.alpn = "openburnbar/2";
  const errors = checkParity(perturbed);
  assert.ok(errors.some((e) => /ALPN|alpn/.test(e)), `expected ALPN drift, got: ${errors.join("; ")}`);
});

test("screamingSnake derives Kotlin enum constants correctly", () => {
  assert.equal(screamingSnake("hostRegister"), "HOST_REGISTER");
  assert.equal(screamingSnake("mediaLongTermReferenceAck"), "MEDIA_LONG_TERM_REFERENCE_ACK");
  assert.equal(screamingSnake("ping"), "PING");
});

test("Swift parser round-trips ping/pong implicit raw values", () => {
  const swift = parseSwiftFrames(
    readFileSync(new URL("../../OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift", import.meta.url), "utf8"),
  );
  const ping = swift.find((f) => f.id === "ping");
  assert.ok(ping, "ping case not parsed");
  assert.equal(ping.wire, "ping");
});

test("Kotlin parser extracts all 41 frames", () => {
  const kotlin = parseKotlinFrames(
    readFileSync(new URL("../../android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/HermesRealtimeRelayFrame.kt", import.meta.url), "utf8"),
  );
  assert.equal(kotlin.length, proto.frames.length);
});

test("codegen rejects an invalid protocol (duplicate wire)", () => {
  const broken = structuredClone(proto);
  broken.frames.push({ id: "dupe", wire: "ping", group: "session", relayAccepted: false });
  assert.throws(() => validateProtocol(broken), /duplicate or missing frame wire: ping/);
});

test("codegen rejects implicitSwiftRawValue when wire !== id", () => {
  const broken = structuredClone(proto);
  broken.frames.push({ id: "weird", wire: "weird.thing", group: "session", relayAccepted: false, implicitSwiftRawValue: true });
  assert.throws(() => validateProtocol(broken), /implicitSwiftRawValue requires wire === id/);
});
