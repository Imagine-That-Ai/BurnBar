/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * All Firestore document shapes, provider enums, and runtime types are
 * centralized here to keep the rest of the codebase strongly typed and
 * self-documenting.
 *
 * The declarations themselves now live in cohesive domain modules under
 * `./legacy/*`. This file is a barrel that re-exports every one of them so
 * each `import ... from ".../types/legacy"` keeps resolving byte-identically.
 */

export * from "./legacy/providers.js";
export * from "./legacy/connections.js";
export * from "./legacy/quota-usage.js";
export * from "./legacy/config.js";
export * from "./legacy/insights-spec.js";
export * from "./legacy/insights-digest.js";
export * from "./legacy/media.js";
