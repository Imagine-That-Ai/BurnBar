import { isRecord, stringValue } from "./guards.js";

/** Parse Firebase Remote Config defaultValue objects shaped like `{ value: string }`. */
export function remoteConfigStringValue(defaultValue: unknown): string | undefined {
  if (!isRecord(defaultValue)) return undefined;
  return stringValue(defaultValue.value);
}

