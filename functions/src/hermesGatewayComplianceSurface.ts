/**
 * Knip entry + compliance pytest surface for Hermes gateway rollout hooks.
 *
 * `tests/test_hermes_gateway_signal_required_mode.py` requires these symbols on
 * the compiled `lib/hermesGateway.js` module. This file pins them as used for
 * dead-code analysis without widening the Cloud Functions deployment surface.
 */

export {
  HERMES_GATEWAY_SIGNAL_REQUIRED_ENV,
  gatewaySignalRequiredMode,
  productionGatewaySignalEnvelopeVersions,
  productionGatewayRelayKeyVersions,
} from "./hermesGateway.js";