use std::collections::HashMap;

use serde_json::Value;

use super::{
    QuotaBucket, QuotaConfidence, QuotaParseResult, QuotaParseStatus, QuotaSnapshot,
    QuotaSourceKind, QuotaUnit, QuotaWindowKind,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AnthropicCredentialShape {
    OauthBearer,
    ConsoleApiKey,
}

pub fn parse_anthropic_rate_limit_headers(
    payload: &[u8],
    now_unix: i64,
    shape: AnthropicCredentialShape,
) -> QuotaParseResult {
    let Ok(Value::Object(raw)) = serde_json::from_slice::<Value>(payload) else {
        return result(QuotaParseStatus::Malformed, now_unix, shape, Vec::new());
    };
    let headers: HashMap<String, f64> = raw
        .into_iter()
        .filter_map(|(key, value)| {
            let number = value
                .as_str()
                .and_then(|text| text.trim().parse().ok())
                .or_else(|| value.as_f64());
            number.map(|number| (key.to_lowercase(), number))
        })
        .collect();
    let mut buckets = Vec::new();
    let unified_limit = get(&headers, "anthropic-ratelimit-unified-tokens-limit");
    let unified_remaining = get(&headers, "anthropic-ratelimit-unified-tokens-remaining");
    if unified_limit.is_some() || unified_remaining.is_some() {
        buckets.push(make_bucket(
            "claude-unified-header-probe",
            "5-hour unified window",
            QuotaWindowKind::RollingHours,
            BucketValues {
                limit: unified_limit,
                remaining: unified_remaining,
                reset: get(&headers, "anthropic-ratelimit-unified-tokens-reset"),
                now_unix,
                unit: QuotaUnit::Tokens,
            },
        ));
    }
    for (suffix, label, unit) in [
        ("requests", "Requests / minute", QuotaUnit::Requests),
        ("input-tokens", "Input tokens / minute", QuotaUnit::Tokens),
        ("output-tokens", "Output tokens / minute", QuotaUnit::Tokens),
    ] {
        let limit = get(&headers, &format!("anthropic-ratelimit-{suffix}-limit"));
        let remaining = get(&headers, &format!("anthropic-ratelimit-{suffix}-remaining"));
        if limit.is_some() || remaining.is_some() {
            buckets.push(make_bucket(
                &format!("claude-rate-limit-{suffix}"),
                label,
                QuotaWindowKind::Custom,
                BucketValues {
                    limit,
                    remaining,
                    reset: get(&headers, &format!("anthropic-ratelimit-{suffix}-reset")),
                    now_unix,
                    unit,
                },
            ));
        }
    }
    let status = if buckets.is_empty() {
        QuotaParseStatus::Empty
    } else {
        QuotaParseStatus::Parsed
    };
    result(status, now_unix, shape, buckets)
}

fn get(headers: &HashMap<String, f64>, name: &str) -> Option<f64> {
    headers.get(name).copied()
}

struct BucketValues {
    limit: Option<f64>,
    remaining: Option<f64>,
    reset: Option<f64>,
    now_unix: i64,
    unit: QuotaUnit,
}

fn make_bucket(
    key: &str,
    label: &str,
    window_kind: QuotaWindowKind,
    values: BucketValues,
) -> QuotaBucket {
    let used_value = values
        .limit
        .zip(values.remaining)
        .map(|(limit, remaining)| limit - remaining);
    let used_percent = values
        .limit
        .filter(|limit| *limit > 0.0)
        .zip(values.remaining)
        .map(|(limit, remaining)| (((limit - remaining) / limit) * 100.0).clamp(0.0, 100.0));
    QuotaBucket {
        key: key.to_owned(),
        label: label.to_owned(),
        window_kind,
        used_value,
        limit_value: values.limit,
        remaining_value: values.remaining,
        used_percent,
        resets_at_unix: values.reset.map(|seconds| values.now_unix as f64 + seconds),
        unit: values.unit,
        is_estimated: false,
    }
}

fn result(
    status: QuotaParseStatus,
    now_unix: i64,
    shape: AnthropicCredentialShape,
    buckets: Vec<QuotaBucket>,
) -> QuotaParseResult {
    let credential = if shape == AnthropicCredentialShape::ConsoleApiKey {
        "Console API key"
    } else {
        "Claude plan"
    };
    QuotaParseResult { status, snapshot: QuotaSnapshot { provider: "claudeCode".to_owned(),
        source: QuotaSourceKind::OfficialApi, confidence: QuotaConfidence::Exact,
        status_message: format!("Claude quota from Anthropic rate-limit headers ({credential}). {} window(s) active.", buckets.len()),
        now_unix: Some(now_unix), buckets } }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{error::Error, fs, path::PathBuf};
    fn fixture(name: &str) -> Result<Vec<u8>, Box<dyn Error>> {
        Ok(fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../tests/fixtures/domain-core/quota/v1")
                .join(name),
        )?)
    }
    #[test]
    fn matches_canonical_fixture() -> Result<(), Box<dyn Error>> {
        let actual = parse_anthropic_rate_limit_headers(
            &fixture("anthropic-ratelimit-headers-input.json")?,
            1_783_036_800,
            AnthropicCredentialShape::OauthBearer,
        );
        let expected: QuotaSnapshot =
            serde_json::from_slice(&fixture("anthropic-ratelimit-headers-expected.json")?)?;
        assert_eq!(actual.snapshot, expected);
        Ok(())
    }
    #[test]
    fn case_insensitive_and_empty_inputs_are_supported() {
        let actual = parse_anthropic_rate_limit_headers(
            br#"{"ANTHROPIC-RATELIMIT-UNIFIED-TOKENS-LIMIT":"100"}"#,
            0,
            AnthropicCredentialShape::OauthBearer,
        );
        assert_eq!(actual.status, QuotaParseStatus::Parsed);
        assert_eq!(
            parse_anthropic_rate_limit_headers(b"{}", 0, AnthropicCredentialShape::OauthBearer)
                .status,
            QuotaParseStatus::Empty
        );
    }
}
