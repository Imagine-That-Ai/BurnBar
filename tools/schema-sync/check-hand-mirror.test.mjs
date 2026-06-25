import assert from "node:assert/strict";
import test from "node:test";

import {
  diffMirror,
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
