/**
 * Resilient HTTP for provider quota adapters.
 * All outbound provider API calls must go through providerFetch.
 */

import { providerResilientFetch } from "../resilienceHelpers.js";

export function providerFetch(
  provider: string,
  operation: string,
  url: string | URL,
  init?: RequestInit,
): Promise<Response> {
  return providerResilientFetch(provider, operation, url, init);
}
