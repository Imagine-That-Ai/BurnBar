import type Stripe from "stripe";

/**
 * Shared checkout policy for both recurring memberships and prepaid top-ups.
 *
 * Stripe Tax is enabled on the live account, but it only calculates and
 * collects tax when each Checkout Session opts in. Because BurnBar always
 * passes an existing Customer, persist the verified billing identity back to
 * that Customer so renewals, invoices, refunds, and the billing portal use the
 * same tax location.
 */
export const STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS = {
  automatic_tax: { enabled: true },
  billing_address_collection: "auto",
  tax_id_collection: { enabled: true },
  customer_update: {
    address: "auto",
    name: "auto",
  },
} satisfies Pick<
  Stripe.Checkout.SessionCreateParams,
  "automatic_tax" | "billing_address_collection" | "customer_update" | "tax_id_collection"
>;
