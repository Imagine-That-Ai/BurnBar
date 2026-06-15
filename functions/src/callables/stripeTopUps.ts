import { HttpsError } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import type { CloudProTopUpKind } from "../cloudProAllowanceCore.js";

export const STRIPE_TOP_UP_KINDS = [
  "agent_control_actions_100",
  "floo_relay_50gb",
  "elder_wand_searches_100",
  "elder_wand_searches_500",
] as const;

export type StripeTopUpKind = (typeof STRIPE_TOP_UP_KINDS)[number];

function requireConfiguredPriceID(priceID: string, label: string): string {
  if (!priceID) throw new HttpsError("failed-precondition", `${label} Stripe price is not configured.`);
  return priceID;
}

export function topUpCheckoutSelection(kind: StripeTopUpKind): { priceID: string; kind: StripeTopUpKind } {
  const cfg = getConfig();
  switch (kind) {
    case "agent_control_actions_100":
      return {
        kind,
        priceID: requireConfiguredPriceID(cfg.stripeAgentControl100ActionsPriceID, "Agent Control 100 hosted actions"),
      };
    case "floo_relay_50gb":
      return {
        kind,
        priceID: requireConfiguredPriceID(cfg.stripeFlooRelay50GBPriceID, "Floo relay 50 GB"),
      };
    case "elder_wand_searches_100":
      return {
        kind,
        priceID: requireConfiguredPriceID(
          cfg.stripeElderWandSearches100PriceID,
          "Elder Wand 100 hosted searches",
        ),
      };
    case "elder_wand_searches_500":
      return {
        kind,
        priceID: requireConfiguredPriceID(
          cfg.stripeElderWandSearches500PriceID,
          "Elder Wand 500 hosted searches",
        ),
      };
  }
}

export function googlePlayTopUpKind(productID: string): CloudProTopUpKind {
  const cfg = getConfig();
  if (
    productID === cfg.googlePlayAgentControl100ActionsProductID ||
    productID === cfg.agentControl100ActionsProductID
  ) {
    return "agent_control_actions_100";
  }
  if (productID === cfg.googlePlayFlooRelay50GBProductID || productID === cfg.flooRelay50GBProductID) {
    return "floo_relay_50gb";
  }
  if (
    productID === cfg.googlePlayElderWandSearches100ProductID ||
    productID === cfg.elderWandSearches100ProductID
  ) {
    return "elder_wand_searches_100";
  }
  if (
    productID === cfg.googlePlayElderWandSearches500ProductID ||
    productID === cfg.elderWandSearches500ProductID
  ) {
    return "elder_wand_searches_500";
  }
  throw new HttpsError("invalid-argument", "Unsupported Google Play top-up product.");
}
