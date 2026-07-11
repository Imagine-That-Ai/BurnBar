import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildKeylimeRegistrarRequest, buildKeylimeTpmVerifyRequest, keylimeResponseLimitForRequest, parseKeylimeTpmVerifyResponse } from "../src/keylimeClient.js";
import { keylimeVerifierResponseHardLimit } from "../src/config.js";
import { PublicError } from "../src/errors.js";
import { policy } from "./helpers.js";

const evidence = {
  agentId: "00000000-0000-8000-8000-000000000000",
  akTpmBase64: "YWstdHBtMmI=",
  ekTpmBase64: "ZWstdHBtMmI=",
  tpmEkPem: "-----BEGIN PUBLIC KEY-----\nZWstdGVzdA==\n-----END PUBLIC KEY-----\n",
  quoteAttestationBase64: "YXR0ZXN0",
  quoteSignatureBase64: "c2lnbmF0dXJl",
  quotePcrValuesBase64: "cGNyLWJsb2I=",
  pcrBank: "sha256" as const,
  pcrSelection: [0, 2, 4, 7, 10] as const,
  qualifyingDataSha256: "ab".repeat(32),
  imaMeasurementList: Buffer.from("10 0123456789abcdef ima-ng sha256:abcdef /usr/bin/openburnbar-daemon\n"),
  measuredBootLog: Buffer.from("uefi-log"),
};

describe("Keylime 7.14.3 v2.5 compatibility", () => {
  // Mirrored from pinned cloud_verifier_tornado.py::_tpm_verify and its echo_json_response envelope.
  it("builds the exact pinned one-shot TPM body and registrar identity body", () => {
    const request = buildKeylimeTpmVerifyRequest(evidence, policy);
    assert.deepEqual(request, {
      type: "tpm",
      data: {
        nonce: Buffer.from(evidence.qualifyingDataSha256, "hex").toString("base64"),
        quote: "rYXR0ZXN0:c2lnbmF0dXJl:cGNyLWJsb2I=",
        hash_alg: "sha256",
        tpm_ak: evidence.akTpmBase64,
        tpm_ek: evidence.ekTpmBase64,
        tpm_policy: JSON.stringify(policy.tpmPolicy),
        runtime_policy: JSON.stringify(policy.runtimePolicy),
        mb_policy: JSON.stringify(policy.measuredBootPolicy),
        ima_measurement_list: evidence.imaMeasurementList.toString("ascii"),
        mb_list: evidence.measuredBootLog.toString("base64"),
      },
    });
    assert.deepEqual(buildKeylimeRegistrarRequest("Y2VydA==", "ZWs=", "YWs="), { ekcert: "Y2VydA==", ek_tpm: "ZWs=", aik_tpm: "YWs=" });
  });

  it("accepts only the pinned success envelope whose claims equal submitted data", () => {
    const submitted = buildKeylimeTpmVerifyRequest(evidence, policy);
    const response = { code: 200, status: "Success", results: { valid: true, failures: [], claims: structuredClone(submitted.data) } };
    assert.equal(parseKeylimeTpmVerifyResponse(response, submitted).valid, true);
    response.results.claims.nonce = "wrong";
    assert.throws(() => parseKeylimeTpmVerifyResponse(response, submitted), /claims/);
  });

  it("maps invalid appraisal to a sanitized result and validates exact UTF-8 IMA text", () => {
    const submitted = buildKeylimeTpmVerifyRequest(evidence, policy);
    const rejected = parseKeylimeTpmVerifyResponse({ code: 200, status: "Success", results: { valid: false, failures: [{ type: "private", context: { message: "PCR secret" } }], claims: {} } }, submitted);
    assert.deepEqual(rejected.valid, false);
    assert.equal(JSON.stringify(rejected).includes("PCR secret"), false);
    const unicodeIma = Buffer.from("10 abc ima-ng sha256:def /opt/Grüße\n", "utf8");
    assert.equal(
      buildKeylimeTpmVerifyRequest({ ...evidence, imaMeasurementList: unicodeIma }, policy).data.ima_measurement_list,
      unicodeIma.toString("utf8"),
    );
    for (const invalid of [Buffer.from([0xff]), Buffer.from("ima\0entry", "utf8")]) {
      assert.throws(() => buildKeylimeTpmVerifyRequest({ ...evidence, imaMeasurementList: invalid }, policy), (error: unknown) => error instanceof PublicError && error.code === "bad_request");
    }
  });

  it("sizes the verifier response bound for Keylime's full echoed evidence claims", () => {
    const evidenceMaxBytes = 16 * 1024 * 1024;
    const hardLimit = keylimeVerifierResponseHardLimit(evidenceMaxBytes);
    assert.equal(hardLimit, 40 * 1024 * 1024);
    assert.ok(keylimeResponseLimitForRequest(4 * 1024 * 1024, hardLimit) > 64 * 1024);
    assert.equal(keylimeResponseLimitForRequest(hardLimit, hardLimit), hardLimit);
  });
});
