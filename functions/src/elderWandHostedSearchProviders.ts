import { HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";

import { errorMessage, isRecord } from "./guards.js";
import { providerFetch } from "./providers/httpClient.js";
import { boundedTrimmedString } from "./callables/shared.js";

const PERPLEXITY_API_KEY = defineSecret("PERPLEXITY_API_KEY");
const TAVILY_API_KEY = defineSecret("TAVILY_API_KEY");
const PERPLEXITY_SEARCH_COST_USD = 0.005;
const TAVILY_BASIC_SEARCH_COST_USD = 0.008;

export const HOSTED_SEARCH_SECRETS = [PERPLEXITY_API_KEY, TAVILY_API_KEY];

type HostedSearchProvider = "perplexity" | "tavily";

interface HostedSearchResult {
  title: string;
  url: string;
  snippet?: string;
  publishedAt?: string;
}

interface ProviderSearchPayload {
  provider: HostedSearchProvider;
  results: HostedSearchResult[];
  costUSD: number;
}

function secretValue(secret: ReturnType<typeof defineSecret>): string {
  try {
    return secret.value().trim();
  } catch {
    return "";
  }
}

export function normalizeProviderResults(raw: unknown[]): HostedSearchResult[] {
  return raw.flatMap((item): HostedSearchResult[] => {
    if (!isRecord(item)) return [];
    const url = typeof item.url === "string" ? item.url.trim() : "";
    if (!url.startsWith("http://") && !url.startsWith("https://")) return [];
    const title =
      boundedTrimmedString(item.title, "result.title", 180, false) ??
      boundedTrimmedString(item.name, "result.name", 180, false) ??
      url;
    const snippet =
      boundedTrimmedString(item.snippet, "result.snippet", 800, false) ??
      boundedTrimmedString(item.content, "result.content", 800, false) ??
      boundedTrimmedString(item.description, "result.description", 800, false);
    const publishedAt =
      boundedTrimmedString(item.date, "result.date", 80, false) ??
      boundedTrimmedString(item.published_date, "result.published_date", 80, false) ??
      boundedTrimmedString(item.last_updated, "result.last_updated", 80, false);
    const result: HostedSearchResult = { title, url };
    if (snippet !== undefined) result.snippet = snippet;
    if (publishedAt !== undefined) result.publishedAt = publishedAt;
    return [result];
  });
}

async function searchPerplexity(query: string, maxResults: number): Promise<ProviderSearchPayload> {
  const apiKey = secretValue(PERPLEXITY_API_KEY);
  if (!apiKey) throw new HttpsError("failed-precondition", "Perplexity Search API key is not configured.");
  const response = await providerFetch("perplexity", "search", "https://api.perplexity.ai/search", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ query, max_results: maxResults }),
  });
  if (!response.ok) throw new HttpsError("unavailable", `Perplexity search returned HTTP ${response.status}.`);
  const json: unknown = await response.json();
  const root = isRecord(json) ? json : {};
  const rawResults = Array.isArray(root.results)
    ? root.results
    : Array.isArray(root.search_results)
      ? root.search_results
      : [];
  return {
    provider: "perplexity",
    results: normalizeProviderResults(rawResults).slice(0, maxResults),
    costUSD: PERPLEXITY_SEARCH_COST_USD,
  };
}

async function searchTavily(query: string, maxResults: number): Promise<ProviderSearchPayload> {
  const apiKey = secretValue(TAVILY_API_KEY);
  if (!apiKey) throw new HttpsError("failed-precondition", "Tavily API key is not configured.");
  const response = await providerFetch("tavily", "search", "https://api.tavily.com/search", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      query,
      search_depth: "basic",
      max_results: maxResults,
      include_answer: false,
      include_images: false,
      include_raw_content: false,
    }),
  });
  if (!response.ok) throw new HttpsError("unavailable", `Tavily search returned HTTP ${response.status}.`);
  const json: unknown = await response.json();
  const root = isRecord(json) ? json : {};
  const rawResults = Array.isArray(root.results) ? root.results : [];
  return {
    provider: "tavily",
    results: normalizeProviderResults(rawResults).slice(0, maxResults),
    costUSD: TAVILY_BASIC_SEARCH_COST_USD,
  };
}

export async function performProviderSearch(query: string, maxResults: number): Promise<ProviderSearchPayload> {
  const errors: string[] = [];
  try {
    return await searchPerplexity(query, maxResults);
  } catch (err) {
    errors.push(errorMessage(err));
  }

  try {
    return await searchTavily(query, maxResults);
  } catch (err) {
    errors.push(errorMessage(err));
  }

  throw new HttpsError("unavailable", "No hosted search provider completed successfully.", {
    providers: ["perplexity", "tavily"],
    errors: errors.slice(0, 4),
  });
}
