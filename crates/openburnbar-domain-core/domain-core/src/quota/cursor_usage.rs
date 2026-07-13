use serde_json::{Map, Value};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

use super::{
    QuotaBucket, QuotaConfidence, QuotaParseResult, QuotaParseStatus, QuotaSnapshot,
    QuotaSourceKind, QuotaUnit, QuotaWindowKind, MAX_QUOTA_PAYLOAD_BYTES,
};

pub fn parse_cursor_usage_quota(payload: &[u8], user_email: Option<&str>) -> QuotaParseResult {
    if payload.len() > MAX_QUOTA_PAYLOAD_BYTES {
        return QuotaParseResult {
            status: QuotaParseStatus::Malformed,
            snapshot: snapshot(
                QuotaSourceKind::Unavailable,
                QuotaConfidence::Unavailable,
                "Cursor usage-summary payload exceeded the bounded contract.".to_owned(),
                Vec::new(),
            ),
        };
    }
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(payload) else {
        return QuotaParseResult {
            status: QuotaParseStatus::Malformed,
            snapshot: snapshot(
                QuotaSourceKind::Unavailable,
                QuotaConfidence::Unavailable,
                "Cursor usage-summary payload was not valid JSON.".to_owned(),
                Vec::new(),
            ),
        };
    };
    let individual = object(&root, "individual_usage", "individualUsage");
    let resets_at_unix = string(&root, "billing_cycle_end", "billingCycleEnd")
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        .map(|value| value.unix_timestamp_nanos() as f64 / 1_000_000_000.0);
    let mut buckets = Vec::new();

    if let Some(plan) = individual
        .and_then(|value| value.get("plan"))
        .and_then(Value::as_object)
    {
        let used = non_negative_number(plan, "used", "used").unwrap_or(0.0) / 100.0;
        let limit = non_negative_number(plan, "limit", "limit").unwrap_or(0.0) / 100.0;
        let auto = percentage(plan, "auto_percent_used", "autoPercentUsed");
        let api = percentage(plan, "api_percent_used", "apiPercentUsed");
        let total = percentage(plan, "total_percent_used", "totalPercentUsed")
            .or_else(|| auto.map(|a| api.map_or(a, |b| (a + b) / 2.0)));
        if limit > 0.0 || used > 0.0 {
            buckets.push(bucket(
                "cursor-plan",
                "Included usage",
                BucketValues {
                    used,
                    limit,
                    remaining: Some((limit - used).max(0.0)),
                    used_percent: total,
                    resets_at_unix,
                    unit: QuotaUnit::Currency,
                },
            ));
        }
        if let Some(value) = auto.filter(|value| *value > 0.0) {
            buckets.push(percent_bucket(
                "cursor-auto",
                "Auto + Composer",
                value,
                resets_at_unix,
            ));
        }
        if let Some(value) = api.filter(|value| *value > 0.0) {
            buckets.push(percent_bucket(
                "cursor-api",
                "API usage",
                value,
                resets_at_unix,
            ));
        }
    }

    if let Some(on_demand) = individual.and_then(|value| object(value, "on_demand", "onDemand")) {
        let used = non_negative_number(on_demand, "used", "used").unwrap_or(0.0) / 100.0;
        let limit = non_negative_number(on_demand, "limit", "limit").unwrap_or(0.0) / 100.0;
        if used > 0.0 || limit > 0.0 {
            buckets.push(bucket(
                "cursor-ondemand",
                "On-demand",
                BucketValues {
                    used,
                    limit,
                    remaining: (limit > 0.0).then_some((limit - used).max(0.0)),
                    used_percent: Some(if limit > 0.0 {
                        used / limit * 100.0
                    } else {
                        0.0
                    }),
                    resets_at_unix,
                    unit: QuotaUnit::Currency,
                },
            ));
        }
    }

    let tier = string(&root, "membership_type", "membershipType")
        .map(capitalized)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "Cursor".to_owned());
    let suffix = user_email
        .filter(|value| !value.is_empty())
        .map_or_else(String::new, |value| format!(" ({value})"));
    let unlimited = boolean(&root, "is_unlimited", "isUnlimited").unwrap_or(false);
    QuotaParseResult {
        status: QuotaParseStatus::Parsed,
        snapshot: snapshot(
            QuotaSourceKind::OfficialApi,
            QuotaConfidence::Exact,
            format!(
                "{tier}{suffix} — {} plan.",
                if unlimited { "Unlimited" } else { "Capped" }
            ),
            buckets,
        ),
    }
}

fn snapshot(
    source: QuotaSourceKind,
    confidence: QuotaConfidence,
    status_message: String,
    buckets: Vec<QuotaBucket>,
) -> QuotaSnapshot {
    QuotaSnapshot {
        provider: "cursor".to_owned(),
        source,
        confidence,
        status_message,
        now_unix: None,
        buckets,
    }
}

struct BucketValues {
    used: f64,
    limit: f64,
    remaining: Option<f64>,
    used_percent: Option<f64>,
    resets_at_unix: Option<f64>,
    unit: QuotaUnit,
}

fn bucket(key: &str, label: &str, values: BucketValues) -> QuotaBucket {
    QuotaBucket {
        key: key.to_owned(),
        label: label.to_owned(),
        window_kind: QuotaWindowKind::Monthly,
        used_value: Some(values.used),
        limit_value: Some(values.limit),
        remaining_value: values.remaining,
        used_percent: values.used_percent,
        resets_at_unix: values.resets_at_unix,
        unit: values.unit,
        is_estimated: false,
    }
}

fn percent_bucket(key: &str, label: &str, value: f64, reset: Option<f64>) -> QuotaBucket {
    bucket(
        key,
        label,
        BucketValues {
            used: value,
            limit: 100.0,
            remaining: Some((100.0 - value).max(0.0)),
            used_percent: Some(value),
            resets_at_unix: reset,
            unit: QuotaUnit::Percent,
        },
    )
}

fn object<'a>(
    value: &'a Map<String, Value>,
    snake: &str,
    camel: &str,
) -> Option<&'a Map<String, Value>> {
    value
        .get(snake)
        .or_else(|| value.get(camel))
        .and_then(Value::as_object)
}
fn string<'a>(value: &'a Map<String, Value>, snake: &str, camel: &str) -> Option<&'a str> {
    value
        .get(snake)
        .or_else(|| value.get(camel))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}
fn number(value: &Map<String, Value>, snake: &str, camel: &str) -> Option<f64> {
    value
        .get(snake)
        .or_else(|| value.get(camel))
        .and_then(Value::as_f64)
        .filter(|number| number.is_finite())
}
fn non_negative_number(value: &Map<String, Value>, snake: &str, camel: &str) -> Option<f64> {
    number(value, snake, camel).filter(|number| *number >= 0.0)
}
fn percentage(value: &Map<String, Value>, snake: &str, camel: &str) -> Option<f64> {
    number(value, snake, camel).filter(|number| (0.0..=100.0).contains(number))
}
fn boolean(value: &Map<String, Value>, snake: &str, camel: &str) -> Option<bool> {
    value
        .get(snake)
        .or_else(|| value.get(camel))
        .and_then(Value::as_bool)
}
fn capitalized(value: &str) -> String {
    value
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase()
            })
        })
        .collect::<Vec<_>>()
        .join(" ")
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
        let actual = parse_cursor_usage_quota(&fixture("cursor-usage-summary-input.json")?, None);
        let expected: QuotaSnapshot =
            serde_json::from_slice(&fixture("cursor-usage-summary-expected.json")?)?;
        assert_eq!(actual.snapshot, expected);
        Ok(())
    }
    #[test]
    fn malformed_payload_is_unavailable() {
        let actual = parse_cursor_usage_quota(b"not json", None);
        assert_eq!(actual.status, QuotaParseStatus::Malformed);
        assert_eq!(actual.snapshot.confidence, QuotaConfidence::Unavailable);
    }
}
