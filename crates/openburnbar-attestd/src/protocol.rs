use base64ct::{Base64, Base64UrlUnpadded, Encoding};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{BrokerError, ErrorCode};

pub const PROTOCOL_VERSION: u32 = 2;
pub const CHALLENGE_PROTOCOL_VERSION: u32 = 1;
pub const ATTESTATION_KIND: &str = "tpm2_ima_signed_verdict_v1";
pub const EVIDENCE_BUNDLE_FORMAT: &str = "openburnbar_tpm_evidence_bundle_v1";
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
pub const MAX_EVIDENCE_BUNDLE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_REQUEST_ID_BYTES: usize = 128;
const MAX_LABEL_BYTES: usize = 160;
const QUOTE_DOMAIN: &[u8] = b"openburnbar.linux.tpm-quote.v1";

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Request {
    DescribeBinding(DescribeBindingRequest),
    Attest(Box<AttestRequest>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DescribeBindingRequest {
    pub request_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AttestRequest {
    pub request_id: String,
    pub challenge: Challenge,
    pub binding: Binding,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Operation {
    DescribeBinding,
    Attest,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawRequest {
    protocol_version: u32,
    request_id: String,
    operation: Operation,
    challenge: Option<Challenge>,
    binding: Option<Binding>,
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

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
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
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Response {
    pub protocol_version: u32,
    pub request_id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binding: Option<Binding>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attestation: Option<Attestation>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorResponse>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Attestation {
    pub challenge_id: String,
    pub challenge: String,
    pub kind: String,
    pub evidence: QuoteEvidence,
    pub evidence_bundle: EvidenceBundle,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QuoteEvidence {
    pub schema_version: u32,
    pub device_id: String,
    pub quote_attestation_base64: String,
    pub quote_signature_base64: String,
    pub quote_pcr_values_base64: String,
    pub pcr_bank: String,
    pub pcr_selection: [u8; 5],
    pub qualifying_data_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceBundle {
    pub descriptor_index: u32,
    pub format: String,
    pub byte_length: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ErrorResponse {
    pub code: String,
    pub message: String,
    pub retryable: bool,
}

impl Request {
    pub fn parse(bytes: &[u8]) -> Result<Self, BrokerError> {
        let raw: RawRequest = serde_json::from_slice(bytes).map_err(|_| {
            BrokerError::new(
                ErrorCode::MalformedRequest,
                "request is not valid broker JSON",
                false,
            )
        })?;
        if raw.protocol_version != PROTOCOL_VERSION {
            return Err(BrokerError::new(
                ErrorCode::UnsupportedProtocol,
                "broker protocol version is unsupported",
                false,
            ));
        }
        if !valid_label(&raw.request_id, MAX_REQUEST_ID_BYTES) {
            return Err(invalid_request());
        }
        match (raw.operation, raw.challenge, raw.binding) {
            (Operation::DescribeBinding, None, None) => {
                Ok(Self::DescribeBinding(DescribeBindingRequest {
                    request_id: raw.request_id,
                }))
            }
            (Operation::Attest, Some(challenge), Some(binding)) => {
                validate_attest_fields(&challenge, &binding)?;
                Ok(Self::Attest(Box::new(AttestRequest {
                    request_id: raw.request_id,
                    challenge,
                    binding,
                })))
            }
            _ => Err(invalid_request()),
        }
    }

    pub fn request_id(&self) -> &str {
        match self {
            Self::DescribeBinding(request) => &request.request_id,
            Self::Attest(request) => &request.request_id,
        }
    }
}

impl Binding {
    pub fn validate(&self) -> Result<(), BrokerError> {
        if !valid_label(&self.app_id, MAX_LABEL_BYTES)
            || !valid_label(&self.device_id, MAX_LABEL_BYTES)
            || !valid_label(&self.app_version, 80)
            || !matches!(self.architecture.as_str(), "aarch64" | "x86_64")
            || !valid_lower_hex(&self.release_digest_sha256, 64)
            || !valid_label(&self.policy_id, MAX_LABEL_BYTES)
            || self.attestation_kind != ATTESTATION_KIND
        {
            return Err(invalid_request());
        }
        Ok(())
    }
}

impl Attestation {
    pub fn validate(&self) -> Result<(), BrokerError> {
        if !valid_label(&self.challenge_id, MAX_LABEL_BYTES)
            || !valid_challenge(&self.challenge)
            || self.kind != ATTESTATION_KIND
            || self.evidence.schema_version != 1
            || !valid_label(&self.evidence.device_id, MAX_LABEL_BYTES)
            || !valid_standard_base64(&self.evidence.quote_attestation_base64, 16_384)
            || !valid_standard_base64(&self.evidence.quote_signature_base64, 4_096)
            || !valid_standard_base64(&self.evidence.quote_pcr_values_base64, 16_384)
            || self.evidence.pcr_bank != "sha256"
            || self.evidence.pcr_selection != [0, 2, 4, 7, 10]
            || !valid_lower_hex(&self.evidence.qualifying_data_sha256, 64)
            || self.evidence_bundle.descriptor_index != 0
            || self.evidence_bundle.format != EVIDENCE_BUNDLE_FORMAT
            || self.evidence_bundle.byte_length == 0
            || self.evidence_bundle.byte_length > MAX_EVIDENCE_BUNDLE_BYTES
            || !valid_lower_hex(&self.evidence_bundle.sha256, 64)
        {
            return Err(BrokerError::new(
                ErrorCode::AttestationFailed,
                "attestation backend returned invalid evidence",
                false,
            ));
        }
        Ok(())
    }
}

impl Response {
    pub fn binding_success(request_id: String, binding: Binding) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            ok: true,
            binding: Some(binding),
            attestation: None,
            error: None,
        }
    }

    pub fn attestation_success(request_id: String, attestation: Attestation) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            ok: true,
            binding: None,
            attestation: Some(attestation),
            error: None,
        }
    }

    pub fn failure(request_id: String, error: &BrokerError) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            ok: false,
            binding: None,
            attestation: None,
            error: Some(ErrorResponse {
                code: error.code().as_str().to_owned(),
                message: error.public_message().to_owned(),
                retryable: error.retryable(),
            }),
        }
    }
}

fn validate_attest_fields(challenge: &Challenge, binding: &Binding) -> Result<(), BrokerError> {
    binding.validate()?;
    if challenge.protocol_version != CHALLENGE_PROTOCOL_VERSION
        || !valid_label(&challenge.challenge_id, MAX_LABEL_BYTES)
        || !valid_challenge(&challenge.challenge)
        || !valid_label(&challenge.app_id, MAX_LABEL_BYTES)
        || !valid_label(&challenge.policy_id, MAX_LABEL_BYTES)
        || challenge.expires_at_millis <= 0
        || challenge.app_id != binding.app_id
        || challenge.policy_id != binding.policy_id
    {
        return Err(invalid_request());
    }
    Ok(())
}

pub fn qualifying_data_sha256(challenge: &str, binding: &Binding) -> Result<String, BrokerError> {
    let challenge_bytes = decode_challenge(challenge)?;
    let fields: [&[u8]; 9] = [
        QUOTE_DOMAIN,
        &challenge_bytes,
        binding.app_id.as_bytes(),
        binding.device_id.as_bytes(),
        binding.app_version.as_bytes(),
        binding.architecture.as_bytes(),
        binding.release_digest_sha256.as_bytes(),
        binding.policy_id.as_bytes(),
        binding.attestation_kind.as_bytes(),
    ];
    let mut hasher = Sha256::new();
    for (index, field) in fields.iter().enumerate() {
        if index > 0 {
            hasher.update([0]);
        }
        hasher.update(field);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn valid_label(value: &str, max_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= max_bytes
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'.' | b'_' | b':' | b'+' | b'-' | b'/' | b'=')
        })
}

fn valid_lower_hex(value: &str, bytes: usize) -> bool {
    value.len() == bytes
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn valid_standard_base64(value: &str, max_bytes: usize) -> bool {
    if value.is_empty() || value.len() > max_bytes {
        return false;
    }
    let mut decoded = vec![0_u8; value.len().saturating_mul(3) / 4 + 3];
    let Ok(decoded) = Base64::decode(value, &mut decoded) else {
        return false;
    };
    let mut canonical = vec![0_u8; value.len().saturating_add(4)];
    Base64::encode(decoded, &mut canonical).is_ok_and(|encoded| encoded == value)
}

fn valid_challenge(value: &str) -> bool {
    decode_challenge(value).is_ok()
}

fn decode_challenge(value: &str) -> Result<[u8; 32], BrokerError> {
    if value.len() != 43 {
        return Err(invalid_request());
    }
    let mut decoded = [0_u8; 32];
    let decoded_slice =
        Base64UrlUnpadded::decode(value, &mut decoded).map_err(|_| invalid_request())?;
    if decoded_slice.len() != decoded.len() {
        return Err(invalid_request());
    }
    let mut canonical = [0_u8; 43];
    let encoded =
        Base64UrlUnpadded::encode(&decoded, &mut canonical).map_err(|_| invalid_request())?;
    if encoded != value {
        return Err(invalid_request());
    }
    Ok(decoded)
}

const fn invalid_request() -> BrokerError {
    BrokerError::new(
        ErrorCode::InvalidRequest,
        "request fields or challenge binding are invalid",
        false,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct GoldenFixture {
        describe_binding_request: serde_json::Value,
        describe_binding_response: Response,
        attest_request: serde_json::Value,
        attest_response: Response,
        unsupported_response: Response,
    }

    fn golden() -> Result<GoldenFixture, serde_json::Error> {
        serde_json::from_str(include_str!(
            "../../../tests/fixtures/linux-attestation/broker-v2-golden.json"
        ))
    }

    #[test]
    fn golden_requests_parse_and_responses_round_trip_exactly(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let fixture = golden()?;
        let describe_bytes = serde_json::to_vec(&fixture.describe_binding_request)?;
        let attest_bytes = serde_json::to_vec(&fixture.attest_request)?;
        assert!(matches!(
            Request::parse(&describe_bytes)?,
            Request::DescribeBinding(_)
        ));
        assert!(matches!(Request::parse(&attest_bytes)?, Request::Attest(_)));
        for response in [
            fixture.describe_binding_response,
            fixture.attest_response,
            fixture.unsupported_response,
        ] {
            let encoded = serde_json::to_value(&response)?;
            let decoded: Response = serde_json::from_value(encoded.clone())?;
            assert_eq!(serde_json::to_value(decoded)?, encoded);
        }
        Ok(())
    }

    #[test]
    fn request_operations_have_disjoint_exact_shapes() -> Result<(), serde_json::Error> {
        let fixture = golden()?;
        let mut describe = fixture.describe_binding_request;
        describe["challenge"] = serde_json::json!({});
        assert_eq!(
            Request::parse(&serde_json::to_vec(&describe)?)
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::MalformedRequest)
        );
        let mut attest = fixture.attest_request;
        attest
            .as_object_mut()
            .map(|object| object.remove("binding"));
        assert_eq!(
            Request::parse(&serde_json::to_vec(&attest)?)
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::InvalidRequest)
        );
        Ok(())
    }

    #[test]
    fn challenge_subprotocol_and_pcr_contract_are_fixed() -> Result<(), serde_json::Error> {
        let fixture = golden()?;
        let mut request = fixture.attest_request;
        request["challenge"]["protocolVersion"] = serde_json::json!(2);
        assert_eq!(
            Request::parse(&serde_json::to_vec(&request)?)
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::InvalidRequest)
        );
        let attestation = fixture
            .attest_response
            .attestation
            .unwrap_or_else(|| Attestation {
                challenge_id: String::new(),
                challenge: String::new(),
                kind: String::new(),
                evidence: QuoteEvidence {
                    schema_version: 0,
                    device_id: String::new(),
                    quote_attestation_base64: String::new(),
                    quote_signature_base64: String::new(),
                    quote_pcr_values_base64: String::new(),
                    pcr_bank: String::new(),
                    pcr_selection: [0; 5],
                    qualifying_data_sha256: String::new(),
                },
                evidence_bundle: EvidenceBundle {
                    descriptor_index: 1,
                    format: String::new(),
                    byte_length: 0,
                    sha256: String::new(),
                },
            });
        assert!(attestation.validate().is_ok());
        let mut invalid_base64 = attestation.clone();
        invalid_base64.evidence.quote_pcr_values_base64 = "AB==".to_owned();
        assert!(invalid_base64.validate().is_err());
        let mut invalid = attestation;
        invalid.evidence.pcr_selection = [0, 1, 2, 3, 4];
        assert!(invalid.validate().is_err());
        Ok(())
    }

    #[test]
    fn golden_qualifying_data_matches_exact_domain_separated_vector(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let fixture = golden()?;
        let request_bytes = serde_json::to_vec(&fixture.attest_request)?;
        let Request::Attest(request) = Request::parse(&request_bytes)? else {
            return Err("golden attest request parsed as wrong operation".into());
        };
        let expected = fixture
            .attest_response
            .attestation
            .map(|attestation| attestation.evidence.qualifying_data_sha256)
            .ok_or("golden attest response is missing attestation")?;
        let actual = qualifying_data_sha256(&request.challenge.challenge, &request.binding)?;
        assert_eq!(actual, expected);

        let mut challenges = vec![format!("A{}", &request.challenge.challenge[1..])];
        let mut noncanonical = request.challenge.challenge.clone();
        noncanonical.replace_range(42..43, "l");
        challenges.push(noncanonical);
        for challenge in challenges {
            if let Ok(digest) = qualifying_data_sha256(&challenge, &request.binding) {
                assert_ne!(digest, actual);
            }
        }

        let mut mutations = Vec::new();
        let mut binding = request.binding.clone();
        binding.app_id = "1:987654321:web:fedcba9876543210".to_owned();
        mutations.push(binding);
        let mut binding = request.binding.clone();
        binding.device_id =
            "ak-sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff".to_owned();
        mutations.push(binding);
        let mut binding = request.binding.clone();
        binding.app_version = "1.0.31".to_owned();
        mutations.push(binding);
        let mut binding = request.binding.clone();
        binding.architecture = "aarch64".to_owned();
        mutations.push(binding);
        let mut binding = request.binding.clone();
        binding.release_digest_sha256 = "f".repeat(64);
        mutations.push(binding);
        let mut binding = request.binding.clone();
        binding.policy_id = "openburnbar-linux-tpm2-ima-v2".to_owned();
        mutations.push(binding);
        let mut binding = request.binding.clone();
        binding.attestation_kind = "tpm2_ima_signed_verdict_v2".to_owned();
        mutations.push(binding);
        for binding in mutations {
            assert_ne!(
                qualifying_data_sha256(&request.challenge.challenge, &binding)?,
                actual
            );
        }
        Ok(())
    }

    #[test]
    fn challenge_requires_exact_canonical_unpadded_base64url() -> Result<(), serde_json::Error> {
        let fixture = golden()?;
        for invalid in [
            "A".repeat(42),
            format!(
                "{}=",
                fixture.attest_request["challenge"]["challenge"]
                    .as_str()
                    .unwrap_or_default()
            ),
            format!(
                "+{}",
                &fixture.attest_request["challenge"]["challenge"]
                    .as_str()
                    .unwrap_or_default()[1..]
            ),
            format!(
                "{}l",
                &fixture.attest_request["challenge"]["challenge"]
                    .as_str()
                    .unwrap_or_default()[..42]
            ),
        ] {
            let mut request = fixture.attest_request.clone();
            request["challenge"]["challenge"] = serde_json::json!(invalid);
            assert_eq!(
                Request::parse(&serde_json::to_vec(&request)?)
                    .err()
                    .map(|error| error.code()),
                Some(ErrorCode::InvalidRequest)
            );
        }
        Ok(())
    }
}
