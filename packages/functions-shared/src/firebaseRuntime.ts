import { isRecord } from "./guards.js";

function globalProperty(name: string): unknown {
  if (!(name in globalThis)) return undefined;
  return Reflect.get(globalThis, name);
}

/** Read Firebase Functions runtime config without unsafe casts at call sites. */
export function readFirebaseFunctionsConfig(): Record<string, unknown> {
  const functionsValue = globalProperty("functions");
  if (!isRecord(functionsValue) || typeof functionsValue.config !== "function") {
    return {};
  }
  const config = functionsValue.config();
  return isRecord(config) ? config : {};
}

/** Nested openburnbar config bucket from Functions runtime config. */
export function readOpenBurnBarFunctionsConfig(): Record<string, unknown> {
  const config = readFirebaseFunctionsConfig();
  const openburnbar = config.openburnbar;
  return isRecord(openburnbar) ? openburnbar : {};
}
