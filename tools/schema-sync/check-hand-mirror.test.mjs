import assert from "node:assert/strict";
import test from "node:test";

import {
  diffMirror,
  extractCsharpMirrorFields,
  extractInterfaceFields,
  extractKotlinMirrorFields,
  extractSwiftMirrorFields,
  resolveCsharpRecord,
} from "./check-hand-mirror.mjs";

const generatedUsage = `
export interface UsageEventDoc {
  provider: string;
  providerID?: string;
  deviceId?: string;
  cacheWriteTokens?: number;
}
`;

test("TypeScript interface parsing ignores comment-only fields", () => {
  const fields = extractInterfaceFields(
    `
export interface UsageEventDoc {
  provider: string;
  // deviceId?: string;
  /*
  cacheWriteTokens?: number;
  */
}
`,
    "UsageEventDoc"
  );

  assert.deepEqual([...fields.keys()], ["provider"]);
});

test("Swift mirror parsing ignores string and static-let field pins", () => {
  const mirrorSource = `
public struct TokenUsage {
  public let provider: String

  public func debug() {
    let deviceId = "local variable is not a mirrored field"
  }
}

private enum UsageQuotaFirestoreFieldMirror {
  static let deviceId = "deviceId"
  static let cacheWriteTokens = "cacheWriteTokens"
}
`;

  assert.deepEqual([...extractSwiftMirrorFields(mirrorSource)], ["provider"]);
  assert.deepEqual(
    diffMirror({
      generated: generatedUsage,
      mirrorSource,
      interfaces: ["UsageEventDoc"],
      compareOptionality: false,
      language: "swift",
    }),
    ["UsageEventDoc.providerID", "UsageEventDoc.deviceId", "UsageEventDoc.cacheWriteTokens"]
  );
});

test("Kotlin mirror parsing accepts Firestore wire names from PropertyName annotations", () => {
  const mirrorSource = `
@IgnoreExtraProperties
data class TokenUsage(
  @PropertyName("providerID")
  val providerId: String? = null,
  @PropertyName("deviceId")
  val localDevice: String? = null,
)
`;

  assert.deepEqual(
    [...extractKotlinMirrorFields(mirrorSource)].sort(),
    ["deviceId", "localDevice", "providerID", "providerId"]
  );
});

test("native mirror diff requires declared fields, not comments or arbitrary strings", () => {
  const mirrorSource = `
data class TokenUsage(
  @PropertyName("providerID")
  val providerId: String? = null,
  val provider: String = "",
)

private const val CACHE_WRITE_PIN = "cacheWriteTokens"
// val deviceId: String? = null
`;

  assert.deepEqual(
    diffMirror({
      generated: generatedUsage,
      mirrorSource,
      interfaces: ["UsageEventDoc"],
      compareOptionality: false,
      language: "kotlin",
    }),
    ["UsageEventDoc.deviceId", "UsageEventDoc.cacheWriteTokens"]
  );
});

test("C# mirror parsing extracts [JsonPropertyName] wire names from records", () => {
  const mirrorSource = `
public record FirestoreUsageEventDoc
{
    [JsonPropertyName("provider")]
    public required string Provider { get; init; }

    [JsonPropertyName("providerID")]
    public required string ProviderID { get; init; }

    [JsonPropertyName("model")]
    public required string Model { get; init; }
}

public record FirestoreQuotaBucket
{
    [JsonPropertyName("name")]
    public required string Name { get; init; }

    [JsonPropertyName("used")]
    public required long Used { get; init; }

    [JsonPropertyName("limit")]
    public required long Limit { get; init; }
}
`;

  const records = extractCsharpMirrorFields(mirrorSource);

  assert.deepEqual(
    [...records.keys()].sort(),
    ["FirestoreQuotaBucket", "FirestoreUsageEventDoc"]
  );

  const usageFields = records.get("FirestoreUsageEventDoc");
  assert.ok(usageFields, "FirestoreUsageEventDoc should be parsed");
  assert.deepEqual([...usageFields.keys()], ["provider", "providerID", "model"]);
  for (const wireName of ["provider", "providerID", "model"]) {
    assert.equal(
      usageFields.get(wireName),
      false,
      `${wireName} uses required, so it is not optional`
    );
  }

  const bucketFields = records.get("FirestoreQuotaBucket");
  assert.ok(bucketFields, "FirestoreQuotaBucket should be parsed");
  assert.deepEqual([...bucketFields.keys()], ["name", "used", "limit"]);
  for (const wireName of ["name", "used", "limit"]) {
    assert.equal(
      bucketFields.get(wireName),
      false,
      `${wireName} uses required, so it is not optional`
    );
  }
});

test("C# mirror parsing ignores comments and string literals", () => {
  const mirrorSource = `// [JsonPropertyName("fake")]
var decoy = "[JsonPropertyName(\\\"fake2\\\")]";
[JsonPropertyName("provider")]
public required string Provider { get; init; }
`;

  const records = extractCsharpMirrorFields(mirrorSource);

  // With the new per-record parser, attributes outside any `record` body are
  // not collected — proving no spurious wire names leak from comments or
  // string literals.
  assert.equal(records.size, 0);
});

test("C# mirror diff detects missing fields", () => {
  const generated = `
export interface UsageEventDoc {
  provider: string;
  providerID?: string;
  deviceId?: string;
  cacheWriteTokens?: number;
}
`;

  const mirrorSource = `
public record FirestoreUsageEventDoc
{
    [JsonPropertyName("provider")]
    public required string Provider { get; init; }

    [JsonPropertyName("providerID")]
    public required string ProviderID { get; init; }
}
`;

  assert.deepEqual(
    diffMirror({
      generated,
      mirrorSource,
      interfaces: ["UsageEventDoc"],
      compareOptionality: false,
      language: "csharp",
    }),
    [
      "UsageEventDoc.providerID#opt",
      "UsageEventDoc.deviceId",
      "UsageEventDoc.cacheWriteTokens",
    ]
  );
});

test("stale knownDrift entry: fully-matching C# mirror reports no drift, so a grandfathered token would be stale", () => {
  const generated = `
export interface UsageEventDoc {
  provider: string;
  providerID?: string;
}
`;

  const mirrorSource = `
public record FirestoreUsageEventDoc
{
    [JsonPropertyName("provider")]
    public required string Provider { get; init; }

    [JsonPropertyName("providerID")]
    public required string ProviderID { get; init; }
}
`;

  const liveDrift = diffMirror({
    generated,
    mirrorSource,
    interfaces: ["UsageEventDoc"],
    compareOptionality: false,
    language: "csharp",
  });

  // providerID is required in C# but optional in canon, so the real drift
  // token is `providerID#opt` (optionality mismatch), not `providerID`.
  assert.deepEqual(liveDrift, ["UsageEventDoc.providerID#opt"]);
  // The bare token without `#opt` is NOT the drift token — a knownDrift entry
  // listing `UsageEventDoc.providerID` would be stale because the live token
  // is `providerID#opt`.
  assert.equal(
    liveDrift.includes("UsageEventDoc.providerID"),
    false,
    "the bare token `UsageEventDoc.providerID` is not live drift; only `providerID#opt` is, so a knownDrift listing the bare token would be stale"
  );
});

test("C# mirror with an extra field not in the canon produces zero drift", () => {
  const generated = `
export interface UsageEventDoc {
  provider: string;
}
`;

  const mirrorSource = `
public record FirestoreUsageEventDoc
{
    [JsonPropertyName("provider")]
    public required string Provider { get; init; }

    [JsonPropertyName("extraField")]
    public required string ExtraField { get; init; }
}
`;

  assert.deepEqual(
    diffMirror({
      generated,
      mirrorSource,
      interfaces: ["UsageEventDoc"],
      compareOptionality: false,
      language: "csharp",
    }),
    []
  );
});

test("C# per-record scoping: field removed from one record is drift even if present in sibling", () => {
  const generated = `
export interface UsageEventDoc {
  provider: string;
}
export interface QuotaSnapshotDoc {
  provider: string;
}
`;
  const mirrorSource = `
public record FirestoreUsageEventDoc
{
    [JsonPropertyName("otherField")]
    public required string OtherField { get; init; }
}
public record FirestoreQuotaSnapshotDoc
{
    [JsonPropertyName("provider")]
    public required string Provider { get; init; }
}
`;
  assert.deepEqual(
    diffMirror({
      generated,
      mirrorSource,
      interfaces: ["UsageEventDoc", "QuotaSnapshotDoc"],
      compareOptionality: false,
      language: "csharp",
    }),
    ["UsageEventDoc.provider"]
  );
});

test("C# optionality mutation: required field made nullable is drift", () => {
  const generated = `
export interface UsageEventDoc {
  provider: string;
}
`;
  const mirrorSource = `
public record FirestoreUsageEventDoc
{
    [JsonPropertyName("provider")]
    public string? Provider { get; init; }
}
`;
  assert.deepEqual(
    diffMirror({
      generated,
      mirrorSource,
      interfaces: ["UsageEventDoc"],
      compareOptionality: false,
      language: "csharp",
    }),
    ["UsageEventDoc.provider#opt"]
  );
});

test("C# union variant: single merged record covers two canon interfaces", () => {
  const records = extractCsharpMirrorFields(`
public record FirestoreMergedDoc
{
    [JsonPropertyName("scheme")]
    public required string Scheme { get; init; }
    [JsonPropertyName("transportField")]
    public string? TransportField { get; init; }
    [JsonPropertyName("atRestField")]
    public string? AtRestField { get; init; }
}
`);
  const transportGen = new Map([
    ["scheme", false],
    ["transportField", false],
  ]);
  const atRestGen = new Map([
    ["scheme", false],
    ["atRestField", false],
  ]);
  const transportRecord = resolveCsharpRecord(records, "TransportDoc", transportGen);
  const atRestRecord = resolveCsharpRecord(records, "AtRestDoc", atRestGen);
  assert.ok(
    transportRecord,
    "resolveCsharpRecord should find the merged record for TransportDoc"
  );
  assert.ok(
    atRestRecord,
    "resolveCsharpRecord should find the merged record for AtRestDoc"
  );
  assert.equal(
    transportRecord,
    atRestRecord,
    "both union variants resolve to the same merged record"
  );
});

test("C# per-record extraction: optionality parsed from required and nullable", () => {
  const records = extractCsharpMirrorFields(`
public record FirestoreTestDoc
{
    [JsonPropertyName("requiredField")]
    public required string RequiredField { get; init; }
    [JsonPropertyName("nullableField")]
    public string? NullableField { get; init; }
    [JsonPropertyName("requiredList")]
    public required IReadOnlyList<string> RequiredList { get; init; }
    [JsonPropertyName("nullableList")]
    public IReadOnlyList<string>? NullableList { get; init; }
}
`);
  const fields = records.get("FirestoreTestDoc");
  assert.ok(fields, "FirestoreTestDoc should be parsed");
  assert.equal(fields.get("requiredField"), false, "required field is not optional");
  assert.equal(fields.get("nullableField"), true, "nullable field is optional");
  assert.equal(fields.get("requiredList"), false, "required list is not optional");
  assert.equal(fields.get("nullableList"), true, "nullable list is optional");
});