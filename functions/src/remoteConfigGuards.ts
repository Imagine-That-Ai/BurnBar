import { isRecord, numberValue, stringValue } from "./guards.js";

/** Parse Firebase Remote Config defaultValue objects shaped like `{ value: string }`. */
export function remoteConfigStringValue(defaultValue: unknown): string | undefined {
  if (!isRecord(defaultValue)) return undefined;
  return stringValue(defaultValue.value);
}

/** Parse Firebase Remote Config defaultValue objects shaped like `{ value: number }`. */
export function remoteConfigNumberValue(defaultValue: unknown): number | undefined {
  if (!isRecord(defaultValue)) return undefined;
  return numberValue(defaultValue.value);
}
