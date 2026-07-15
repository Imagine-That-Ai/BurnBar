import assert from "node:assert/strict";
import test from "node:test";

import {
  diffMirror,
  extractCsharpMirrorFields,
  extractInterfaceFields,
  extractKotlinMirrorFields,
  extractSwiftMirrorFields,
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

  assert.deepEqual(
    [...extractCsharpMirrorFields(mirrorSource)].sort(),
    ["limit", "model", "name", "provider", "providerID", "used"]
  );
});

test("C# mirror parsing ignores comments and string literals", () => {
  const mirrorSource = `// [JsonPropertyName("fake")]
var decoy = "[JsonPropertyName(\\\"fake2\\\")]";
[JsonPropertyName("provider")]
public required string Provider { get; init; }
`;

  const fields = extractCsharpMirrorFields(mirrorSource);

  assert.equal(fields.has("fake"), false);
  assert.equal(fields.has("fake2"), false);
  assert.deepEqual([...fields], ["provider"]);
});

test("C# mirror diff detects missing fields when compareOptionality is false", () => {
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
    ["UsageEventDoc.deviceId", "UsageEventDoc.cacheWriteTokens"]
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

  assert.deepEqual(liveDrift, []);
  assert.equal(
    liveDrift.includes("UsageEventDoc.providerID"),
    false,
    "diffMirror does not report providerID as drift for a fully-matching mirror; if knownDrift listed it, checkMirror's stale-grandfather path would fire because the token is no longer real drift"
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
