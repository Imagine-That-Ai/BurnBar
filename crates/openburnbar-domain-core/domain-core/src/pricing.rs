//! Checked, deterministic token pricing and model-name compatibility rules.

use serde::{Deserialize, Serialize};
use thiserror::Error;

const TOKENS_PER_MILLION: u128 = 1_000_000;
const ROUND_HALF_UP: u128 = TOKENS_PER_MILLION / 2;
const LEGACY_KIMI_MODEL: &str = "kimi-for-coding";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenRates {
    pub input_nano_usd_per_m_token: u64,
    pub output_nano_usd_per_m_token: u64,
    pub cache_creation_nano_usd_per_m_token: Option<u64>,
    pub cache_read_nano_usd_per_m_token: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBuckets {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyKimiMetrics {
    pub model: String,
    pub total_tokens: u64,
    pub cost_nano_usd: u64,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PricingError {
    #[error("pricing arithmetic overflow")]
    ArithmeticOverflow,
}

pub const fn legacy_kimi_rates() -> TokenRates {
    TokenRates {
        input_nano_usd_per_m_token: 600_000_000,
        output_nano_usd_per_m_token: 2_500_000_000,
        cache_creation_nano_usd_per_m_token: Some(600_000_000),
        cache_read_nano_usd_per_m_token: 150_000_000,
    }
}

pub const fn legacy_kimi_model() -> &'static str {
    LEGACY_KIMI_MODEL
}

/// Returns the nearest integer nano-USD, with exact half-nano ties rounded up.
///
/// Each token/rate product and their sum are checked in `u128`. Rounding occurs
/// once, after accumulation, so splitting usage among buckets cannot introduce
/// multiple rounding steps.
pub fn token_cost_nano_usd(rates: TokenRates, buckets: TokenBuckets) -> Result<u64, PricingError> {
    let cache_creation_rate = rates
        .cache_creation_nano_usd_per_m_token
        .unwrap_or(rates.input_nano_usd_per_m_token);
    let terms = [
        (buckets.input_tokens, rates.input_nano_usd_per_m_token),
        (buckets.output_tokens, rates.output_nano_usd_per_m_token),
        (buckets.cache_creation_tokens, cache_creation_rate),
        (
            buckets.cache_read_tokens,
            rates.cache_read_nano_usd_per_m_token,
        ),
    ];
    let numerator = terms
        .into_iter()
        .try_fold(0_u128, |total, (tokens, rate)| {
            let term = u128::from(tokens)
                .checked_mul(u128::from(rate))
                .ok_or(PricingError::ArithmeticOverflow)?;
            total
                .checked_add(term)
                .ok_or(PricingError::ArithmeticOverflow)
        })?;
    let rounded = numerator
        .checked_add(ROUND_HALF_UP)
        .ok_or(PricingError::ArithmeticOverflow)?
        / TOKENS_PER_MILLION;
    u64::try_from(rounded).map_err(|_| PricingError::ArithmeticOverflow)
}

pub fn is_legacy_kimi_wire_event(provider: &str, model: &str) -> bool {
    provider.eq_ignore_ascii_case("kimi") && model.starts_with("chatcmpl-")
}

pub fn legacy_kimi_metrics(buckets: TokenBuckets) -> Result<LegacyKimiMetrics, PricingError> {
    let input = buckets
        .input_tokens
        .saturating_sub(buckets.cache_creation_tokens)
        .saturating_sub(buckets.cache_read_tokens);
    let normalized = TokenBuckets {
        input_tokens: input,
        ..buckets
    };
    let total_tokens = input
        .checked_add(buckets.output_tokens)
        .and_then(|total| total.checked_add(buckets.cache_creation_tokens))
        .and_then(|total| total.checked_add(buckets.cache_read_tokens))
        .ok_or(PricingError::ArithmeticOverflow)?;
    Ok(LegacyKimiMetrics {
        model: LEGACY_KIMI_MODEL.to_owned(),
        total_tokens,
        cost_nano_usd: token_cost_nano_usd(legacy_kimi_rates(), normalized)?,
    })
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
        expected_cost_nano_usd: u64,
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
            "../../../../tests/fixtures/domain-core/pricing/v2/pricing-kat.json"
        ))
    }

    #[test]
    fn canonical_vectors_match() -> Result<(), Box<dyn std::error::Error>> {
        let fixture = fixture()?;
        assert_eq!(fixture.schema, "openburnbar.domain-core.pricing.v2");
        for vector in fixture.cost_vectors {
            assert_eq!(
                token_cost_nano_usd(vector.rates, vector.buckets)?,
                vector.expected_cost_nano_usd
            );
        }
        for vector in fixture.legacy_kimi_vectors {
            assert_eq!(
                is_legacy_kimi_wire_event(&vector.provider, &vector.model),
                vector.is_legacy
            );
            if let Some(expected) = vector.expected {
                assert_eq!(legacy_kimi_metrics(vector.buckets)?, expected);
            }
        }
        Ok(())
    }

    #[test]
    fn rounds_once_half_up() {
        let rates = TokenRates {
            input_nano_usd_per_m_token: 1,
            output_nano_usd_per_m_token: 1,
            cache_creation_nano_usd_per_m_token: None,
            cache_read_nano_usd_per_m_token: 1,
        };
        let below_half = TokenBuckets {
            input_tokens: 499_999,
            output_tokens: 0,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
        };
        let exact_half = TokenBuckets {
            input_tokens: 250_000,
            output_tokens: 250_000,
            ..below_half
        };
        assert_eq!(token_cost_nano_usd(rates, below_half), Ok(0));
        assert_eq!(token_cost_nano_usd(rates, exact_half), Ok(1));
    }

    #[test]
    fn rejects_accumulation_and_result_overflow() {
        let maximum = TokenRates {
            input_nano_usd_per_m_token: u64::MAX,
            output_nano_usd_per_m_token: u64::MAX,
            cache_creation_nano_usd_per_m_token: Some(u64::MAX),
            cache_read_nano_usd_per_m_token: u64::MAX,
        };
        let maximum_buckets = TokenBuckets {
            input_tokens: u64::MAX,
            output_tokens: u64::MAX,
            cache_creation_tokens: u64::MAX,
            cache_read_tokens: u64::MAX,
        };
        assert_eq!(
            token_cost_nano_usd(maximum, maximum_buckets),
            Err(PricingError::ArithmeticOverflow)
        );
    }

    #[test]
    fn cost_is_monotonic_for_each_bucket_until_overflow() -> Result<(), PricingError> {
        let rates = legacy_kimi_rates();
        for seed in 0_u64..512 {
            let base = TokenBuckets {
                input_tokens: seed * 17,
                output_tokens: seed * 13,
                cache_creation_tokens: seed * 7,
                cache_read_tokens: seed * 5,
            };
            let base_cost = token_cost_nano_usd(rates, base)?;
            for increased in [
                TokenBuckets {
                    input_tokens: base.input_tokens + 1,
                    ..base
                },
                TokenBuckets {
                    output_tokens: base.output_tokens + 1,
                    ..base
                },
                TokenBuckets {
                    cache_creation_tokens: base.cache_creation_tokens + 1,
                    ..base
                },
                TokenBuckets {
                    cache_read_tokens: base.cache_read_tokens + 1,
                    ..base
                },
            ] {
                assert!(token_cost_nano_usd(rates, increased)? >= base_cost);
            }
        }
        Ok(())
    }
}
