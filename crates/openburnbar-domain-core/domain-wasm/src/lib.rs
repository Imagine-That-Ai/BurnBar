use openburnbar_domain_core::cloudvault::{
    self, CloudVaultAadContext, CloudVaultError, CloudVaultHashPurpose as CoreHashPurpose,
};
use openburnbar_domain_core::pricing::{self, TokenBuckets, TokenRates};
use wasm_bindgen::prelude::*;

#[wasm_bindgen(js_name = domainCoreVersion)]
pub fn domain_core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[wasm_bindgen(js_name = calculateTokenCost)]
pub fn calculate_token_cost(rates: &[f64], buckets: &[f64]) -> Result<f64, JsError> {
    if rates.len() != 4 || buckets.len() != 4 {
        return Err(JsError::new(
            "invalid_pricing_vector: expected four rates and four token buckets",
        ));
    }
    Ok(pricing::token_cost(
        TokenRates {
            input_per_m_token: rates[0],
            output_per_m_token: rates[1],
            cache_creation_per_m_token: (!rates[2].is_nan()).then_some(rates[2]),
            cache_read_per_m_token: rates[3],
        },
        TokenBuckets {
            input_tokens: buckets[0],
            output_tokens: buckets[1],
            cache_creation_tokens: buckets[2],
            cache_read_tokens: buckets[3],
        },
    ))
}

#[wasm_bindgen(js_name = isLegacyKimiWireEvent)]
pub fn is_legacy_kimi_wire_event(provider: &str, model: &str) -> bool {
    pricing::is_legacy_kimi_wire_event(provider, model)
}

/// Returns `[total_tokens, cost_usd]`; the canonical model is exported separately.
#[wasm_bindgen(js_name = priceLegacyKimiWireEvent)]
pub fn price_legacy_kimi_wire_event(
    input_tokens: f64,
    output_tokens: f64,
    cache_creation_tokens: f64,
    cache_read_tokens: f64,
) -> Vec<f64> {
    let result = pricing::legacy_kimi_metrics(TokenBuckets {
        input_tokens,
        output_tokens,
        cache_creation_tokens,
        cache_read_tokens,
    });
    vec![result.total_tokens, result.cost_usd]
}

#[wasm_bindgen(js_name = legacyKimiWireModel)]
pub fn legacy_kimi_wire_model() -> String {
    pricing::legacy_kimi_model().to_owned()
}

#[wasm_bindgen]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudVaultHashPurpose {
    BlobIntegrity,
    SessionBody,
    SessionChunk,
    ProjectMemoryContent,
}

impl From<CloudVaultHashPurpose> for CoreHashPurpose {
    fn from(value: CloudVaultHashPurpose) -> Self {
        match value {
            CloudVaultHashPurpose::BlobIntegrity => Self::BlobIntegrity,
            CloudVaultHashPurpose::SessionBody => Self::SessionBody,
            CloudVaultHashPurpose::SessionChunk => Self::SessionChunk,
            CloudVaultHashPurpose::ProjectMemoryContent => Self::ProjectMemoryContent,
        }
    }
}

#[wasm_bindgen(js_name = cloudVaultAadV2)]
pub fn cloud_vault_aad_v2(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: u32,
    purpose: Option<String>,
) -> Result<String, JsError> {
    Ok(context(uid, collection, doc_id, field, schema_version, purpose)?.v2_string())
}

#[wasm_bindgen(js_name = cloudVaultAadV1)]
pub fn cloud_vault_aad_v1(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: u32,
    purpose: Option<String>,
) -> Result<String, JsError> {
    Ok(context(uid, collection, doc_id, field, schema_version, purpose)?.v1_string())
}

#[wasm_bindgen(js_name = cloudVaultSha256Hex)]
pub fn cloud_vault_sha256_hex(data: &[u8]) -> String {
    cloudvault::sha256_hex(data)
}

#[wasm_bindgen(js_name = cloudVaultKeyId)]
pub fn cloud_vault_key_id(key: &[u8]) -> Result<String, JsError> {
    cloudvault::vault_key_id(key).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultKeyedHashHex)]
pub fn cloud_vault_keyed_hash_hex(
    data: &[u8],
    key: &[u8],
    purpose: CloudVaultHashPurpose,
) -> Result<String, JsError> {
    cloudvault::keyed_hash_hex(data, key, purpose.into()).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultExpectedSessionBodyHash)]
pub fn cloud_vault_expected_session_body_hash(
    data: &[u8],
    key: &[u8],
    body_hash_version: u32,
) -> Result<String, JsError> {
    cloudvault::expected_session_body_hash(data, key, body_hash_version).map_err(js_error)
}

fn context(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: u32,
    purpose: Option<String>,
) -> Result<CloudVaultAadContext, JsError> {
    CloudVaultAadContext::new(
        uid,
        collection,
        doc_id,
        field,
        schema_version,
        purpose.as_deref(),
    )
    .map_err(js_error)
}

fn js_error(error: CloudVaultError) -> JsError {
    let code = match error {
        CloudVaultError::InvalidKeyLength => "invalid_key_length",
        CloudVaultError::InvalidAadPart => "invalid_aad_part",
        CloudVaultError::InvalidSchemaVersion => "invalid_schema_version",
        CloudVaultError::AadMismatch => "aad_mismatch",
        CloudVaultError::LegacyAadRejected => "legacy_aad_rejected",
        CloudVaultError::UnsupportedHashVersion => "unsupported_hash_version",
        CloudVaultError::DerivationFailure => "derivation_failure",
    };
    JsError::new(&format!("{code}: {error}"))
}
