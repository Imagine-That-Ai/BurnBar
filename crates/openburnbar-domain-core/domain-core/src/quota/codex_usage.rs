use serde_json::Value;

use super::{
    QuotaBucket, QuotaConfidence, QuotaParseResult, QuotaParseStatus, QuotaSnapshot,
    QuotaSourceKind, QuotaUnit, QuotaWindowKind,
};

pub fn parse_codex_usage_quota(payload: &[u8], now_unix: i64) -> QuotaParseResult {
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(payload) else {
        return result(QuotaParseStatus::Malformed, now_unix, Vec::new(), "Codex");
    };

    let mut buckets = Vec::new();
    if let Some(rate_limit) = root.get("rate_limit") {
        append_windows(&mut buckets, rate_limit, "codex", None, now_unix);
    }
    if let Some(Value::Array(lanes)) = root.get("additional_rate_limits") {
        for lane in lanes.iter().take(8) {
            let Some(label) = lane
                .get("limit_name")
                .and_then(Value::as_str)
                .map(str::trim)
            else {
                continue;
            };
            if label.is_empty() {
                continue;
            }
            if let Some(rate_limit) = lane.get("rate_limit") {
                append_windows(
                    &mut buckets,
                    rate_limit,
                    &format!("codex-{}", slug(label)),
                    Some(label),
                    now_unix,
                );
            }
        }
    }

    let status = if buckets.is_empty() {
        QuotaParseStatus::Empty
    } else {
        QuotaParseStatus::Parsed
    };
    let plan = root
        .get("plan_type")
        .and_then(Value::as_str)
        .map(capitalized)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "Codex".to_owned());
    result(status, now_unix, buckets, &plan)
}

fn append_windows(
    buckets: &mut Vec<QuotaBucket>,
    rate_limit: &Value,
    prefix: &str,
    label_prefix: Option<&str>,
    now_unix: i64,
) {
    let Some(object) = rate_limit.as_object() else {
        return;
    };
    for (field, suffix, default_label, fallback_kind) in [
        (
            "primary_window",
            "5h",
            "5-hour window",
            QuotaWindowKind::RollingHours,
        ),
        (
            "secondary_window",
            "7d",
            "7-day window",
            QuotaWindowKind::RollingDays,
        ),
    ] {
        let Some(window) = object.get(field).and_then(Value::as_object) else {
            continue;
        };
        let Some(raw_used) = window.get("used_percent").and_then(Value::as_f64) else {
            continue;
        };
        let used = raw_used.clamp(0.0, 100.0);
        let window_kind = window
            .get("limit_window_seconds")
            .and_then(Value::as_i64)
            .filter(|value| *value > 0)
            .map_or(fallback_kind, |value| {
                if value >= 86_400 {
                    QuotaWindowKind::RollingDays
                } else {
                    QuotaWindowKind::RollingHours
                }
            });
        let resets_at_unix = window
            .get("reset_at")
            .and_then(Value::as_i64)
            .filter(|value| *value > 0)
            .map(|value| value as f64)
            .or_else(|| {
                window
                    .get("reset_after_seconds")
                    .and_then(Value::as_i64)
                    .filter(|value| *value >= 0)
                    .map(|value| (now_unix + value) as f64)
            });
        buckets.push(QuotaBucket {
            key: format!("{prefix}-{suffix}"),
            label: label_prefix.map_or_else(
                || default_label.to_owned(),
                |label| format!("{label} {default_label}"),
            ),
            window_kind,
            used_value: Some(used),
            limit_value: Some(100.0),
            remaining_value: Some((100.0 - used).max(0.0)),
            used_percent: Some(used),
            resets_at_unix,
            unit: QuotaUnit::Percent,
            is_estimated: false,
        });
    }
}

fn result(
    status: QuotaParseStatus,
    now_unix: i64,
    buckets: Vec<QuotaBucket>,
    plan: &str,
) -> QuotaParseResult {
    QuotaParseResult {
        status,
        snapshot: QuotaSnapshot {
            provider: "codex".to_owned(),
            source: QuotaSourceKind::OfficialApi,
            confidence: QuotaConfidence::Exact,
            status_message: format!("{plan} quota snapshot from the local Codex login session."),
            now_unix: Some(now_unix),
            buckets,
        },
    }
}

fn slug(value: &str) -> String {
    let mut result = String::new();
    let mut separator = false;
    for character in value.to_lowercase().chars() {
        if character.is_alphanumeric() {
            if separator && !result.is_empty() {
                result.push('-');
            }
            separator = false;
            result.push(character);
        } else {
            separator = true;
        }
    }
    if result.is_empty() {
        "additional".to_owned()
    } else {
        result
    }
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
        let actual = parse_codex_usage_quota(&fixture("codex-usage-input.json")?, 1_783_036_800);
        let expected: QuotaSnapshot =
            serde_json::from_slice(&fixture("codex-usage-expected.json")?)?;
        assert_eq!(actual.status, QuotaParseStatus::Parsed);
        assert_eq!(actual.snapshot, expected);
        Ok(())
    }

    #[test]
    fn empty_and_clamped_inputs_are_distinguished() {
        assert_eq!(
            parse_codex_usage_quota(br#"{"plan_type":"pro"}"#, 0).status,
            QuotaParseStatus::Empty
        );
        let parsed = parse_codex_usage_quota(
            br#"{"rate_limit":{"primary_window":{"used_percent":137.5}}}"#,
            0,
        );
        assert_eq!(parsed.snapshot.buckets[0].used_percent, Some(100.0));
    }
}
