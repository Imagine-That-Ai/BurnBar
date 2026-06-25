import { defineSecret } from "firebase-functions/params";

type SecretParam = ReturnType<typeof defineSecret>;

export const MODEL_LANDSCAPE_SECRET_NAMES = ["ARTIFICIAL_ANALYSIS_API_KEY", "DESIGN_ARENA_API_KEY"] as const;

const ARTIFICIAL_ANALYSIS_API_KEY: SecretParam = defineSecret(MODEL_LANDSCAPE_SECRET_NAMES[0]);
const DESIGN_ARENA_API_KEY: SecretParam = defineSecret(MODEL_LANDSCAPE_SECRET_NAMES[1]);

export const MODEL_LANDSCAPE_SECRETS: SecretParam[] = [ARTIFICIAL_ANALYSIS_API_KEY, DESIGN_ARENA_API_KEY];

export function resolveModelLandscapeEnv(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  return {
    ...env,
    ARTIFICIAL_ANALYSIS_API_KEY: ARTIFICIAL_ANALYSIS_API_KEY.value() || env.ARTIFICIAL_ANALYSIS_API_KEY,
    DESIGN_ARENA_API_KEY: DESIGN_ARENA_API_KEY.value() || env.DESIGN_ARENA_API_KEY,
  };
}
