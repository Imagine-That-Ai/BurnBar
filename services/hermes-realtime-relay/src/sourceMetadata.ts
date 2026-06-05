const SOURCE_REPOSITORY = process.env.OPENBURNBAR_SOURCE_REPOSITORY ?? "https://github.com/Imagine-That-Ai/BurnBar";
const CORRESPONDING_SOURCE_URL = process.env.OPENBURNBAR_CORRESPONDING_SOURCE_URL ?? "https://burnbar.ai/legal/source";

export function sourceMetadata() {
  return {
    license: "AGPL-3.0-only",
    source: {
      repository: SOURCE_REPOSITORY,
      commit: process.env.OPENBURNBAR_SOURCE_COMMIT ?? process.env.SOURCE_COMMIT ?? process.env.GIT_SHA ?? "unknown",
      correspondingSource: CORRESPONDING_SOURCE_URL,
    },
  } as const;
}
