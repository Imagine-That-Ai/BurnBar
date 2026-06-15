import type { BolaCoverageRef } from "./bolaCoverageTypes.js";

const AUTH_ONLY_FILE = "functions/src/__tests__/bola/authOnly.bola.test.ts";
const HIGH_RISK_GUARDS_FILE = "functions/src/__tests__/highRiskOwnerActionCallableGuards.test.ts";
const COMPUTER_USE_RULES_FILE = "firestore-rules-tests/computer-use.test.js";
const SESSION_LOG_RULES_FILE = "firestore-rules-tests/session-log-backup.test.js";

export function authOnlyCoverage(exportedName: string): BolaCoverageRef {
  return {
    file: AUTH_ONLY_FILE,
    test: "rejects unauthenticated callable access",
    kind: "auth-only",
    covers: [exportedName],
    expectedOutcome: "throws",
    expectedCode: "unauthenticated",
  };
}

export function runtimeCoverage(args: {
  file: string;
  test: string;
  exportedName: string;
  expectedCode?: BolaCoverageRef["expectedCode"];
  expectedOutcome?: BolaCoverageRef["expectedOutcome"];
}): BolaCoverageRef {
  return {
    file: args.file,
    test: args.test,
    kind: "runtime-cross-user",
    covers: [args.exportedName],
    expectedCode: args.expectedCode ?? "not-found",
    expectedOutcome: args.expectedOutcome ?? "throws",
  };
}

export function firestoreRulesCoverage(args: {
  file: string;
  test: string;
  exportedName: string;
}): BolaCoverageRef {
  return {
    file: args.file,
    test: args.test,
    kind: "firestore-rules",
    covers: [args.exportedName],
  };
}

export function staticHighRiskWiringCoverage(exportedName: string): BolaCoverageRef {
  return {
    file: HIGH_RISK_GUARDS_FILE,
    test: `${exportedName} calls enforceHighRiskOwnerAction with actionKind`,
    kind: "static-high-risk-wiring",
    covers: [exportedName],
  };
}

export function platformTriggerCoverage(exportedName: string): BolaCoverageRef {
  return {
    file: AUTH_ONLY_FILE,
    test: "platform triggers are not client-callable",
    kind: "platform-trigger",
    covers: [exportedName],
  };
}

export function publicHealthCoverage(exportedName: string): BolaCoverageRef {
  return {
    file: AUTH_ONLY_FILE,
    test: "public health endpoints do not expose tenant objects",
    kind: "not-applicable-public",
    covers: [exportedName],
  };
}

export const COMPUTER_USE_RULES_CROSS_USER = firestoreRulesCoverage({
  file: COMPUTER_USE_RULES_FILE,
  test: "user cannot create a session in another user's namespace",
  exportedName: "client-firestore-computer-use",
});

export const SESSION_LOG_RULES_CROSS_USER = firestoreRulesCoverage({
  file: SESSION_LOG_RULES_FILE,
  test: "session-log manifest cannot be written into another user namespace",
  exportedName: "client-firestore-session-log",
});