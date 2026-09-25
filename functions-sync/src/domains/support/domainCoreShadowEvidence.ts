import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { enforceAuthAndAppCheck } from "@openburnbar/functions-shared/auth.js";
import { getConfig } from "@openburnbar/functions-shared/config.js";
import {
  domainCoreShadowStore,
  enforceDomainCoreShadowChannelClaim,
  persistDomainCoreShadowSamples,
  parseDomainCoreShadowSampleRequest,
} from "@openburnbar/functions-shared/domainCoreShadowEvidence.js";
import { onCallProduction } from "@openburnbar/functions-shared/logging.js";
import { firestoreWithResilience } from "@openburnbar/functions-shared/resilienceHelpers.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";

export const submitDomainCoreShadowSamples = onCallProduction(
  "submitDomainCoreShadowSamples",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
  },
  async (request: CallableRequest<unknown>) => {
    const auth = request.auth;
    if (!auth?.uid) throw new HttpsError("unauthenticated", "Sign in before submitting shadow evidence.");
    enforceAuthAndAppCheck(request, auth.uid);
    const nowMillis = Date.now();
    const samples = parseDomainCoreShadowSampleRequest(request.data, nowMillis);
    enforceDomainCoreShadowChannelClaim(auth.token, samples);
    return firestoreWithResilience("submitDomainCoreShadowSamples", () =>
      persistDomainCoreShadowSamples(domainCoreShadowStore(db), samples, nowMillis),
    );
  },
);
