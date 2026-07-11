export type EndpointTrigger =
  | "callable"
  | "http"
  | "scheduled"
  | "firestore-trigger"
  | "task-queue"
  | "provider-webhook";

export type BolaCoverageKind =
  | "runtime-cross-user"
  | "firestore-rules"
  | "static-high-risk-wiring"
  | "auth-only"
  | "platform-trigger"
  | "not-applicable-public";

export type BolaExpectedCode = "permission-denied" | "not-found" | "failed-precondition" | "unauthenticated";

export type BolaCoverageRef = {
  file: string;
  test: string;
  kind: BolaCoverageKind;
  covers: string[];
  expectedOutcome?: "throws" | "no-side-effect";
  expectedCode?: BolaExpectedCode;
};

export type LowerTrustDesktopPolicy =
  | "not-applicable"
  | "deny"
  | "linux-low-risk"
  | "desktop-attestation-binding"
  | "desktop-nonce-bootstrap"
  | "desktop-trusted-device-step-up";

export type EndpointAuthorizationEntry = {
  exportedName: string;
  trigger: EndpointTrigger;
  authMethod: string;
  appCheck: "required" | "not-applicable" | "not-required";
  lowerTrustDesktopPolicy: LowerTrustDesktopPolicy;
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
