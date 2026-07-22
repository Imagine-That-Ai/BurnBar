use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum QuotaParseStatus {
    Parsed,
    Empty,
    Malformed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum QuotaSourceKind {
    OfficialApi,
    LocalCli,
    LocalSession,
    ManualEstimate,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum QuotaConfidence {
    Exact,
    Estimated,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum QuotaUnit {
    Percent,
    Requests,
    Tokens,
    Sessions,
    Lines,
    Files,
    Count,
    Currency,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum QuotaWindowKind {
    RollingHours,
    RollingDays,
    Daily,
    Weekly,
    Monthly,
    Lifetime,
    Custom,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaBucket {
    pub key: String,
    pub label: String,
    pub window_kind: QuotaWindowKind,
    pub used_value: Option<f64>,
    pub limit_value: Option<f64>,
    pub remaining_value: Option<f64>,
    pub used_percent: Option<f64>,
    pub resets_at_unix: Option<f64>,
    pub unit: QuotaUnit,
    pub is_estimated: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub provider: String,
    pub source: QuotaSourceKind,
    pub confidence: QuotaConfidence,
    pub status_message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub now_unix: Option<i64>,
    pub buckets: Vec<QuotaBucket>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct QuotaParseResult {
    pub status: QuotaParseStatus,
    pub snapshot: QuotaSnapshot,
}
