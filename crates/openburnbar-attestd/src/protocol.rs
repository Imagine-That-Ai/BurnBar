use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{BrokerError, ErrorCode};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
const MAX_REQUEST_ID_BYTES: usize = 128;
const MAX_LABEL_BYTES: usize = 160;
const MAX_CHALLENGE_BYTES: usize = 256;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub protocol_version: u32,
    pub request_id: String,
    pub operation: Operation,
    pub challenge: Challenge,
    pub binding: Binding,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Attest,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Challenge {
    pub challenge_id: String,
    pub challenge: String,
    pub expires_at_millis: i64,
    pub app_id: String,
    pub policy_id: String,
    pub protocol_version: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    pub app_id: String,
    pub device_id: String,
    pub app_version: String,
    pub architecture: String,
    pub release_digest_sha256: String,
    pub policy_id: String,
    pub attestation_kind: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    pub protocol_version: u32,
    pub request_id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attestation: Option<Attestation>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorResponse>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Attestation {
    pub challenge_id: String,
    pub challenge: String,
    pub kind: String,
    pub evidence: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ErrorResponse {
    pub code: String,
    pub message: String,
    pub retryable: bool,
}

impl Request {
    pub fn parse(bytes: &[u8]) -> Result<Self, BrokerError> {
        let request: Self = serde_json::from_slice(bytes).map_err(|_| {
            BrokerError::new(
                ErrorCode::MalformedRequest,
                "request is not valid broker JSON",
                false,
            )
        })?;
        request.validate()?;
        Ok(request)
    }

    fn validate(&self) -> Result<(), BrokerError> {
        if self.protocol_version != PROTOCOL_VERSION
            || self.challenge.protocol_version != PROTOCOL_VERSION
        {
            return Err(BrokerError::new(
                ErrorCode::UnsupportedProtocol,
                "broker protocol version is unsupported",
                false,
            ));
        }
        if !valid_label(&self.request_id, MAX_REQUEST_ID_BYTES)
            || !valid_label(&self.challenge.challenge_id, MAX_LABEL_BYTES)
            || !valid_label(&self.challenge.challenge, MAX_CHALLENGE_BYTES)
            || !valid_label(&self.binding.device_id, MAX_LABEL_BYTES)
            || !valid_label(&self.binding.app_version, 80)
            || !valid_label(&self.binding.architecture, 24)
            || !valid_label(&self.binding.attestation_kind, 80)
            || !valid_label(&self.binding.app_id, MAX_LABEL_BYTES)
            || !valid_label(&self.binding.policy_id, MAX_LABEL_BYTES)
            || self.challenge.app_id != self.binding.app_id
            || self.challenge.policy_id != self.binding.policy_id
            || self.challenge.expires_at_millis <= 0
            || self.binding.release_digest_sha256.len() != 64
            || !self
                .binding
                .release_digest_sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(BrokerError::new(
                ErrorCode::InvalidRequest,
                "request fields or challenge binding are invalid",
                false,
            ));
        }
        Ok(())
    }
}

impl Response {
    pub fn success(request_id: String, attestation: Attestation) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            ok: true,
            attestation: Some(attestation),
            error: None,
        }
    }

    pub fn failure(request_id: String, error: &BrokerError) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            ok: false,
            attestation: None,
            error: Some(ErrorResponse {
                code: error.code().as_str().to_owned(),
                message: error.public_message().to_owned(),
                retryable: error.retryable(),
            }),
        }
    }
}

fn valid_label(value: &str, max_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= max_bytes
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'.' | b'_' | b':' | b'+' | b'-' | b'/' | b'=')
        })
}
