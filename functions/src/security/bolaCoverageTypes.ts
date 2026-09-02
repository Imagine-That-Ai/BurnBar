export type EndpointTrigger =
  | "callable"
  | "http"
  | "scheduled"
  | "firestore-trigger"
  | "pubsub-trigger"
  | "task-queue"
  | "provider-webhook";

export type BolaCoverageKind =
  | "runtime-cross-user"
  | "firestore-rules"
  | "static-high-risk-wiring"
  | "auth-only"
  | "platform-trigger"
  | "not-applicable-public";

export type BolaExpectedCode =
  | "permission-denied"
  | "not-found"
  | "failed-precondition"
  | "unauthenticated"
  | "invalid-argument"
  | "already-exists";

/**
 * What the generated BOLA ledger records per object-id endpoint: a measured
 * denial code, or an explicit no-side-effect outcome for auth-scoped endpoints
 * whose cross-user invocation may succeed without touching victim rows.
 */
export type BolaLedgerCode = BolaExpectedCode | "no-side-effect";

export type BolaCoverageRef = {
  file: string;
  test: string;
  kind: BolaCoverageKind;
  covers: string[];
  expectedOutcome?: "throws" | "no-side-effect";
  expectedCode?: BolaExpectedCode;
};

export type EndpointAuthorizationEntry = {
  exportedName: string;
  trigger: EndpointTrigger;
  authMethod: string;
  appCheck: "required" | "not-applicable" | "not-required";
  tenantSource: string;
  objectIdsFromClient: string[];
  ownershipCheck: string;
  bolaCoverage: BolaCoverageRef[];
  clientFirestoreSurface?: boolean;
  handlerModule?: string;
  highRiskComputerUse: boolean;
  actionKind?: string;
  publicJustification?: string;
  notes?: string;
};
