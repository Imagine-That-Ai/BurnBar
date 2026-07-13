//! Deterministic token pricing and model-name compatibility rules.

use serde::{Deserialize, Serialize};

const TOKENS_PER_MILLION: f64 = 1_000_000.0;
const LEGACY_KIMI_MODEL: &str = "kimi-for-coding";

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenRates {
    pub input_per_m_token: f64,
    pub output_per_m_token: f64,
    pub cache_creation_per_m_token: Option<f64>,
    pub cache_read_per_m_token: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBuckets {
    pub input_tokens: f64,
    pub output_tokens: f64,
    pub cache_creation_tokens: f64,
    pub cache_read_tokens: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyKimiMetrics {
    pub model: String,
    pub total_tokens: f64,
    pub cost_usd: f64,
}

pub const fn legacy_kimi_rates() -> TokenRates {
    TokenRates {
        input_per_m_token: 0.6,
        output_per_m_token: 2.5,
        cache_creation_per_m_token: Some(0.6),
        cache_read_per_m_token: 0.15,
    }
}

pub const fn legacy_kimi_model() -> &'static str {
    LEGACY_KIMI_MODEL
}

/// Reproduces the established Swift/TypeScript operation order exactly.
pub fn token_cost(rates: TokenRates, buckets: TokenBuckets) -> f64 {
    let cache_creation_rate = rates
        .cache_creation_per_m_token
        .unwrap_or(rates.input_per_m_token);
    buckets.input_tokens / TOKENS_PER_MILLION * rates.input_per_m_token
        + buckets.output_tokens / TOKENS_PER_MILLION * rates.output_per_m_token
        + buckets.cache_creation_tokens / TOKENS_PER_MILLION * cache_creation_rate
        + buckets.cache_read_tokens / TOKENS_PER_MILLION * rates.cache_read_per_m_token
}

pub fn is_legacy_kimi_wire_event(provider: &str, model: &str) -> bool {
    provider.to_lowercase() == "kimi" && model.starts_with("chatcmpl-")
}

pub fn legacy_kimi_metrics(buckets: TokenBuckets) -> LegacyKimiMetrics {
    let input =
        (buckets.input_tokens - buckets.cache_creation_tokens - buckets.cache_read_tokens).max(0.0);
    let normalized = TokenBuckets {
        input_tokens: input,
        ..buckets
    };
    LegacyKimiMetrics {
        model: LEGACY_KIMI_MODEL.to_owned(),
        total_tokens: input
            + buckets.output_tokens
            + buckets.cache_creation_tokens
            + buckets.cache_read_tokens,
        cost_usd: token_cost(legacy_kimi_rates(), normalized),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        schema: String,
        cost_vectors: Vec<CostVector>,
        legacy_kimi_vectors: Vec<KimiVector>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CostVector {
        rates: TokenRates,
        buckets: TokenBuckets,
        expected_cost_usd: f64,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct KimiVector {
        provider: String,
        model: String,
        buckets: TokenBuckets,
        is_legacy: bool,
        expected: Option<LegacyKimiMetrics>,
    }

    fn fixture() -> Result<Fixture, serde_json::Error> {
        serde_json::from_slice(include_bytes!(
            "../../../../tests/fixtures/domain-core/pricing/v1/pricing-kat.json"
        ))
    }

    #[test]
    fn canonical_vectors_match() -> Result<(), serde_json::Error> {
        let fixture = fixture()?;
        assert_eq!(fixture.schema, "openburnbar.domain-core.pricing.v1");
        for vector in fixture.cost_vectors {
            assert_eq!(
                token_cost(vector.rates, vector.buckets).to_bits(),
                vector.expected_cost_usd.to_bits()
            );
        }
        for vector in fixture.legacy_kimi_vectors {
            assert_eq!(
                is_legacy_kimi_wire_event(&vector.provider, &vector.model),
                vector.is_legacy
            );
            if let Some(expected) = vector.expected {
                assert_eq!(legacy_kimi_metrics(vector.buckets), expected);
            }
        }
        Ok(())
    }
}
