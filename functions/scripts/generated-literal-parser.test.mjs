import { strict as assert } from "node:assert";
import test from "node:test";

import { parseGeneratedLiteral } from "./generated-literal-parser.mjs";

test("parseGeneratedLiteral parses generated TypeScript literal shape", () => {
  assert.deepEqual(
    parseGeneratedLiteral(`[
      {
        exportedName: "example",
        objectIdsFromClient: ["deviceId", "requestId"],
        highRiskComputerUse: false,
        retryCount: 2,
        weight: -3,
        metadata: null,
      },
    ]`),
    [
      {
        exportedName: "example",
        objectIdsFromClient: ["deviceId", "requestId"],
        highRiskComputerUse: false,
        retryCount: 2,
        weight: -3,
        metadata: null,
      },
    ],
  );
});

test("parseGeneratedLiteral rejects executable expressions", () => {
  assert.throws(
    () => parseGeneratedLiteral(`[{ exportedName: "x", payload: (() => process.env.SECRET)() }]`),
    /value must be a JSON-like literal/u,
  );
  assert.throws(() => parseGeneratedLiteral(`Function("return process.env")()`), /value must be a JSON-like literal/u);
});

test("parseGeneratedLiteral rejects non-literal object constructs", () => {
  assert.throws(() => parseGeneratedLiteral(`[{ ...other }]`), /only property assignments/u);
  assert.throws(() => parseGeneratedLiteral(`[{ [name]: "value" }]`), /object keys must be static/u);
  assert.throws(() => parseGeneratedLiteral(`[{ key }]`), /only property assignments/u);
});

test("parseGeneratedLiteral treats prototype names as inert data keys", () => {
  const [value] = parseGeneratedLiteral(`[{ __proto__: "data", constructor: "also-data" }]`);
  assert.equal(value.__proto__, "data");
  assert.equal(value.constructor, "also-data");
  assert.equal(Object.getPrototypeOf(value), Object.prototype);
});

test("parseGeneratedLiteral rejects extra statements", () => {
  assert.throws(() => parseGeneratedLiteral(`[]; process.exit(1)`), /expected exactly one literal expression/u);
});
