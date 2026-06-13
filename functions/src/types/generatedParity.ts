/**
 * Compile-time parity pins for the schema-sync generated canon (WP4-SCHEMACANON).
 *
 * The hermes-gateway domain is the first domain migrated for real onto the
 * TypeSpec canon: tools/schema-sync/check-tsp-canon.mjs proves the .tsp
 * compiles and matches the emitted functions/src/types/generated/hermes-gateway.ts,
 * and THIS file proves — on every `tsc` run — that the emitted canon is
 * byte-for-byte type-identical to:
 *
 *   1. the doc types the runtime registry (functions/src/hermesGateway.ts)
 *      exports, and
 *   2. the @openburnbar/signal-envelope-contracts envelope types the runtime
 *      aliases for the signalEnvelope sub-documents.
 *
 * Since WP5-GW-REEXPORT the runtime registry RE-EXPORTS the generated canon
 * instead of hand-maintaining duplicate interfaces, so pin set 1 holds by
 * construction today. The pins stay deliberately: they fail the build the
 * moment anyone unfolds a re-export back into a local hand copy that drifts
 * from the canon. Pin set 2 still guards real drift between emit/generate.mjs,
 * the .tsp, and the contracts package.
 *
 * `Equals` is the exact-type-identity trick (it distinguishes `a?: string`
 * from a missing field and from `a: string | undefined`, unlike mutual
 * `extends`), so any drift between emit/generate.mjs, the .tsp, and the
 * runtime types breaks the functions build instead of rotting silently.
 */

import type {
  SignalAtRestKeyDelivery,
  SignalAtRestWrap,
  SignalBinding,
  SignalCiphertextLayer,
  SignalEnvelope,
  SignalTransportKeyDelivery,
} from "@openburnbar/signal-envelope-contracts";

import type {
  GatewayRatchetEnvelopeDoc,
  GatewayRatchetHeaderDoc,
  GatewayRelayEnvelopeDoc,
  HermesGatewayApprovalDoc,
  HermesGatewayAttachmentManifestDoc,
  HermesGatewayClientDoc,
  HermesGatewayDestinationDoc,
  HermesGatewayEventDoc,
  HermesGatewayMessageDoc,
  HermesGatewayModelOptionDoc,
} from "../hermesGateway.js";

import type * as Generated from "./generated/hermes-gateway.js";

/** True only when A and B are exactly the same type. */
type Equals<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;
type Assert<T extends true> = T;

// Generated canon ≡ runtime registry (functions/src/hermesGateway.ts).
type AssertModelOptionDocParity = Assert<
  Equals<Generated.HermesGatewayModelOptionDoc, HermesGatewayModelOptionDoc>
>;
type AssertRelayEnvelopeDocParity = Assert<Equals<Generated.GatewayRelayEnvelopeDoc, GatewayRelayEnvelopeDoc>>;
type AssertRatchetHeaderDocParity = Assert<Equals<Generated.GatewayRatchetHeaderDoc, GatewayRatchetHeaderDoc>>;
type AssertRatchetEnvelopeDocParity = Assert<
  Equals<Generated.GatewayRatchetEnvelopeDoc, GatewayRatchetEnvelopeDoc>
>;
type AssertClientDocParity = Assert<Equals<Generated.HermesGatewayClientDoc, HermesGatewayClientDoc>>;
type AssertApprovalDocParity = Assert<Equals<Generated.HermesGatewayApprovalDoc, HermesGatewayApprovalDoc>>;
type AssertDestinationDocParity = Assert<
  Equals<Generated.HermesGatewayDestinationDoc, HermesGatewayDestinationDoc>
>;
type AssertEventDocParity = Assert<Equals<Generated.HermesGatewayEventDoc, HermesGatewayEventDoc>>;
type AssertMessageDocParity = Assert<Equals<Generated.HermesGatewayMessageDoc, HermesGatewayMessageDoc>>;
type AssertAttachmentManifestDocParity = Assert<
  Equals<Generated.HermesGatewayAttachmentManifestDoc, HermesGatewayAttachmentManifestDoc>
>;

// Generated canon ≡ @openburnbar/signal-envelope-contracts.
type AssertSignalCiphertextLayerParity = Assert<
  Equals<Generated.GatewaySignalCiphertextLayerDoc, SignalCiphertextLayer>
>;
type AssertSignalBindingParity = Assert<Equals<Generated.GatewaySignalBindingDoc, SignalBinding>>;
type AssertSignalAtRestWrapParity = Assert<Equals<Generated.GatewaySignalAtRestWrapDoc, SignalAtRestWrap>>;
type AssertSignalTransportKeyDeliveryParity = Assert<
  Equals<Generated.GatewaySignalTransportKeyDeliveryDoc, SignalTransportKeyDelivery>
>;
type AssertSignalAtRestKeyDeliveryParity = Assert<
  Equals<Generated.GatewaySignalAtRestKeyDeliveryDoc, SignalAtRestKeyDelivery>
>;
type AssertSignalEnvelopeParity = Assert<Equals<Generated.GatewaySignalEnvelopeDoc, SignalEnvelope>>;

type SchemaParityAssertions = [
  AssertModelOptionDocParity,
  AssertRelayEnvelopeDocParity,
  AssertRatchetHeaderDocParity,
  AssertRatchetEnvelopeDocParity,
  AssertClientDocParity,
  AssertApprovalDocParity,
  AssertDestinationDocParity,
  AssertEventDocParity,
  AssertMessageDocParity,
  AssertAttachmentManifestDocParity,
  AssertSignalCiphertextLayerParity,
  AssertSignalBindingParity,
  AssertSignalAtRestWrapParity,
  AssertSignalTransportKeyDeliveryParity,
  AssertSignalAtRestKeyDeliveryParity,
  AssertSignalEnvelopeParity,
];

void (null as unknown as SchemaParityAssertions);
