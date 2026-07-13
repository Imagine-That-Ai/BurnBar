use serde_json::{Map, Value};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

use super::types::{
    QuotaBucket, QuotaConfidence, QuotaParseResult, QuotaParseStatus, QuotaSnapshot,
    QuotaSourceKind, QuotaUnit, QuotaWindowKind,
};

const PROVIDER: &str = "claudeCode";
const STATUS_MESSAGE: &str = "Quota captured from Claude Code's local status line JSON bridge.";
const USED_KEYS: &[&str] = &[
    "used_percentage",
    "usedPercent",
    "percentage",
    "utilization",
    "used",
];
const REMAINING_KEYS: &[&str] = &["remaining_percentage", "remainingPercent"];
const RESET_KEYS: &[&str] = &["resets_at", "reset_at", "resetTime"];
const WINDOW_CANDIDATES: &[(&str, &str, QuotaWindowKind)] = &[
    ("five_hour", "5-hour window", QuotaWindowKind::RollingHours),
    ("seven_day", "7-day window", QuotaWindowKind::RollingDays),
    (
        "seven_day_sonnet",
        "7-day Sonnet window",
        QuotaWindowKind::RollingDays,
    ),
    (
        "seven_day_opus",
        "7-day Opus window",
        QuotaWindowKind::RollingDays,
    ),
    (
        "seven_day_oauth_apps",
        "7-day OAuth Apps window",
        QuotaWindowKind::RollingDays,
    ),
];

#[derive(Clone, Copy, Debug)]
struct ParsedWindow {
    used: Option<f64>,
    remaining: Option<f64>,
    reset_unix: Option<f64>,
}

#[must_use]
pub fn parse_claude_statusline_quota(payload: &[u8]) -> QuotaParseResult {
    let empty_snapshot = || QuotaSnapshot {
        provider: PROVIDER.to_owned(),
        source: QuotaSourceKind::LocalCli,
        confidence: QuotaConfidence::Exact,
        status_message: STATUS_MESSAGE.to_owned(),
        now_unix: None,
        buckets: Vec::new(),
    };

    let Ok(root) = serde_json::from_slice::<Value>(payload) else {
        return QuotaParseResult {
            status: QuotaParseStatus::Malformed,
            snapshot: empty_snapshot(),
        };
    };
    let Some(root_map) = root.as_object() else {
        return QuotaParseResult {
            status: QuotaParseStatus::Malformed,
            snapshot: empty_snapshot(),
        };
    };
    let rate_limits = root_map
        .get("rate_limits")
        .and_then(Value::as_object)
        .unwrap_or(root_map);

    let buckets = WINDOW_CANDIDATES
        .iter()
        .filter_map(|(key, label, window_kind)| {
            let payload = rate_limits.get(*key)?.as_object()?;
            let window = parse_window(payload)?;
            if window.used.is_none() && window.remaining.is_none() {
                return None;
            }
            Some(QuotaBucket {
                key: format!("claude-{key}"),
                label: (*label).to_owned(),
                window_kind: *window_kind,
                used_value: window.used,
                limit_value: Some(100.0),
                remaining_value: window.remaining,
                used_percent: window.used,
                resets_at_unix: window.reset_unix,
                unit: QuotaUnit::Percent,
                is_estimated: false,
            })
        })
        .collect::<Vec<_>>();

    let status = if buckets.is_empty() {
        QuotaParseStatus::Empty
    } else {
        QuotaParseStatus::Parsed
    };
    QuotaParseResult {
        status,
        snapshot: QuotaSnapshot {
            buckets,
            ..empty_snapshot()
        },
    }
}

fn parse_window(payload: &Map<String, Value>) -> Option<ParsedWindow> {
    let used = first_number(payload, USED_KEYS);
    let remaining = first_number(payload, REMAINING_KEYS)
        .or_else(|| used.map(|value| (100.0 - value).max(0.0)));
    let reset_unix = first_date(payload, RESET_KEYS);
    (used.is_some() || remaining.is_some() || reset_unix.is_some()).then_some(ParsedWindow {
        used,
        remaining,
        reset_unix,
    })
}

fn first_number(payload: &Map<String, Value>, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| match payload.get(*key) {
        Some(Value::Number(value)) => value.as_f64(),
        Some(Value::String(value)) => value.parse::<f64>().ok(),
        _ => None,
    })
}

fn first_date(payload: &Map<String, Value>, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| match payload.get(*key) {
        Some(Value::Number(value)) => value.as_f64(),
        Some(Value::String(value)) => OffsetDateTime::parse(value, &Rfc3339)
            .map(|date| date.unix_timestamp_nanos() as f64 / 1_000_000_000.0)
            .ok()
            .or_else(|| value.parse::<f64>().ok()),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use std::{error::Error, fs, path::PathBuf};

    use super::*;

    fn fixture(name: &str) -> Result<Vec<u8>, Box<dyn Error>> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/fixtures/domain-core/quota/v1")
            .join(name);
        Ok(fs::read(path)?)
    }

    #[test]
    fn matches_canonical_claude_fixture() -> Result<(), Box<dyn Error>> {
        let result = parse_claude_statusline_quota(&fixture("claude-statusline-input.json")?);
        let expected: QuotaSnapshot =
            serde_json::from_slice(&fixture("claude-statusline-expected.json")?)?;

        assert_eq!(result.status, QuotaParseStatus::Parsed);
        assert_eq!(result.snapshot.provider, expected.provider);
        assert_eq!(result.snapshot.source, expected.source);
        assert_eq!(result.snapshot.confidence, expected.confidence);
        assert_eq!(result.snapshot.status_message, expected.status_message);
        assert_eq!(result.snapshot.buckets.len(), expected.buckets.len());
        for (actual, expected) in result.snapshot.buckets.iter().zip(expected.buckets.iter()) {
            assert_eq!(actual.key, expected.key);
            assert_eq!(actual.label, expected.label);
            assert_eq!(actual.window_kind, expected.window_kind);
            assert_optional_f64(actual.resets_at_unix, expected.resets_at_unix);
            assert_eq!(actual.unit, expected.unit);
            assert_eq!(actual.is_estimated, expected.is_estimated);
            assert_optional_f64(actual.used_value, expected.used_value);
            assert_optional_f64(actual.limit_value, expected.limit_value);
            assert_optional_f64(actual.remaining_value, expected.remaining_value);
            assert_optional_f64(actual.used_percent, expected.used_percent);
        }
        Ok(())
    }

    #[test]
    fn accepts_bare_windows_and_fractional_rfc3339_resets() {
        let result = parse_claude_statusline_quota(
            br#"{
                "five_hour": {"utilization": "100", "resets_at": "2026-05-17T18:40:00.399875+00:00"},
                "seven_day": {"remainingPercent": 82}
            }"#,
        );

        assert_eq!(result.status, QuotaParseStatus::Parsed);
        assert_eq!(result.snapshot.buckets.len(), 2);
        assert_eq!(result.snapshot.buckets[0].used_value, Some(100.0));
        assert_eq!(result.snapshot.buckets[0].remaining_value, Some(0.0));
        assert_optional_f64(
            result.snapshot.buckets[0].resets_at_unix,
            Some(1_779_043_200.399_875),
        );
        assert_eq!(result.snapshot.buckets[1].remaining_value, Some(82.0));
    }

    #[test]
    fn ignores_unknown_and_reset_only_windows() {
        let result = parse_claude_statusline_quota(
            br#"{
                "rate_limits": {
                    "seven_day_oauth_apps": {"resets_at": 1720000000},
                    "marketing_window": {"used_percentage": 5}
                }
            }"#,
        );

        assert_eq!(result.status, QuotaParseStatus::Empty);
        assert!(result.snapshot.buckets.is_empty());
    }

    #[test]
    fn malformed_or_non_object_json_is_distinguished_from_empty_json() {
        assert_eq!(
            parse_claude_statusline_quota(b"not json").status,
            QuotaParseStatus::Malformed
        );
        assert_eq!(
            parse_claude_statusline_quota(b"[]").status,
            QuotaParseStatus::Malformed
        );
        assert_eq!(
            parse_claude_statusline_quota(b"{}").status,
            QuotaParseStatus::Empty
        );
    }

    fn assert_optional_f64(actual: Option<f64>, expected: Option<f64>) {
        assert_eq!(actual.is_some(), expected.is_some());
        if let (Some(actual), Some(expected)) = (actual, expected) {
            assert!(
                (actual - expected).abs() <= 1e-6,
                "expected {expected}, got {actual}"
            );
        }
    }
}
