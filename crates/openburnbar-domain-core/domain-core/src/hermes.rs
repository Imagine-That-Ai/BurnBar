use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use p256::PublicKey;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

const AAD_PREFIX: &str = "OpenBurnBar-HermesRelay-v1";
const KEY_WRAP_V1_PREFIX: &[u8] = b"OpenBurnBar-HermesRelay-KeyWrap-v1|";
const KEY_WRAP_V2_PREFIX: &[u8] = b"OpenBurnBar-HermesRelay-KeyWrap-v2|";
const HPKE_V3_PREFIX: &[u8] = b"OpenBurnBar-HermesRelay-HPKE-v3|";
const RATCHET_PREKEY_KDF_DOMAIN: &[u8] = b"OpenBurnBar-HermesRatchet-v1-prekey-x3dh-p256";
const RATCHET_CHAT_LANE: &str = "chat";
const AES_KEY_LEN: usize = 32;
const GCM_NONCE_LEN: usize = 12;
const GCM_TAG_LEN: usize = 16;
const P256_X963_PUBLIC_KEY_LEN: usize = 65;
const MAX_AAD_ARGUMENT_BYTES: usize = 4 * 1024;
const MAX_AAD_BYTES: usize = 64 * 1024;
const MAX_CRYPTO_INPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_BASE64_INPUT_BYTES: usize =
    (MAX_CRYPTO_INPUT_BYTES + GCM_NONCE_LEN + GCM_TAG_LEN).div_ceil(3) * 4;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AadKind {
    Request,
    Key,
    AuthenticatedRequest,
    AuthenticatedKey,
    Chunk,
    MediaSealKey,
    ControlSealKey,
    GatewayEvent,
    GatewayEventKey,
    GatewayMessage,
    GatewayMessageKey,
    GatewayAttachmentKey,
    GatewayAttachmentManifest,
    GatewayAttachmentBody,
}

impl AadKind {
    fn label(self) -> &'static str {
        match self {
            Self::Request => "request",
            Self::Key => "key",
            Self::AuthenticatedRequest => "request-v3",
            Self::AuthenticatedKey => "key-v3",
            Self::Chunk => "chunk",
            Self::MediaSealKey => "mediaSealKey",
            Self::ControlSealKey => "controlSealKey",
            Self::GatewayEvent => "gatewayEvent",
            Self::GatewayEventKey => "gatewayEventKey",
            Self::GatewayMessage => "gatewayMessage",
            Self::GatewayMessageKey => "gatewayMessageKey",
            Self::GatewayAttachmentKey => "gatewayAttachmentKey",
            Self::GatewayAttachmentManifest => "gatewayAttachmentManifest",
            Self::GatewayAttachmentBody => "gatewayAttachmentBody",
        }
    }

    fn argument_count(self) -> usize {
        match self {
            Self::Request | Self::Key => 3,
            Self::AuthenticatedRequest | Self::AuthenticatedKey => 8,
            Self::Chunk => 5,
            Self::MediaSealKey | Self::ControlSealKey => 6,
            Self::GatewayEvent
            | Self::GatewayEventKey
            | Self::GatewayMessage
            | Self::GatewayMessageKey
            | Self::GatewayAttachmentKey
            | Self::GatewayAttachmentManifest
            | Self::GatewayAttachmentBody => 3,
        }
    }
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum HermesError {
    #[error("Hermes AAD argument count does not match its domain")]
    InvalidAadArguments,
    #[error("Hermes symmetric keys must be exactly 32 bytes")]
    InvalidKeyLength,
    #[error("Hermes AES-GCM nonces must be exactly 12 bytes")]
    InvalidNonceLength,
    #[error("Hermes ciphertext is malformed")]
    InvalidCiphertext,
    #[error("Hermes AES-GCM authentication failed")]
    AuthenticationFailed,
    #[error("Hermes HKDF output length is invalid")]
    InvalidHkdfLength,
    #[error("Hermes HMAC initialization failed")]
    HmacFailure,
    #[error("Hermes AAD components must not contain pipes or ASCII controls")]
    InvalidAadComponent,
    #[error("Hermes input exceeds its bounded contract")]
    InputTooLarge,
    #[error("Hermes P-256 keys must be exact on-curve 65-byte X9.63 points")]
    InvalidP256PublicKey,
    #[error("Hermes ratchet ECDH outputs must each be exactly 32 bytes")]
    InvalidRatchetSharedSecretLength,
}

pub struct RatchetPrekeyRequest<'a> {
    pub dh1: &'a [u8],
    pub dh2: &'a [u8],
    pub dh3: &'a [u8],
    pub uid: &'a str,
    pub client_id: &'a str,
    pub initiator_role: &'a str,
    pub initiator_identity_public_key_base64: &'a str,
    pub responder_identity_public_key_base64: &'a str,
    pub initiator_signed_prekey_public_key_base64: &'a str,
    pub responder_signed_prekey_public_key_base64: &'a str,
    pub initiator_initial_ratchet_public_key_base64: &'a str,
}

pub fn aad(kind: AadKind, arguments: &[String]) -> Result<Vec<u8>, HermesError> {
    if arguments.len() != kind.argument_count() {
        return Err(HermesError::InvalidAadArguments);
    }
    let total_argument_bytes = arguments.iter().try_fold(0_usize, |total, argument| {
        if argument.is_empty()
            || argument.len() > MAX_AAD_ARGUMENT_BYTES
            || argument
                .bytes()
                .any(|byte| byte == b'|' || byte <= 0x1f || byte == 0x7f)
        {
            return Err(HermesError::InvalidAadComponent);
        }
        total
            .checked_add(argument.len())
            .ok_or(HermesError::InputTooLarge)
    })?;
    if total_argument_bytes > MAX_AAD_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    let mut value = String::from(AAD_PREFIX);
    value.push('|');
    value.push_str(kind.label());
    for argument in arguments {
        value.push('|');
        value.push_str(argument);
    }
    Ok(value.into_bytes())
}

pub fn key_wrap_info_v1(aad: &[u8]) -> Result<Vec<u8>, HermesError> {
    require_aad_bound(aad)?;
    bounded_concat(KEY_WRAP_V1_PREFIX, &[aad])
}

pub fn key_wrap_info_v2(
    aad: &[u8],
    enc: &[u8],
    recipient: &[u8],
    sender: &[u8],
) -> Result<Vec<u8>, HermesError> {
    require_aad_bound(aad)?;
    validate_p256_x963(enc)?;
    validate_p256_x963(recipient)?;
    validate_p256_x963(sender)?;
    bounded_concat(KEY_WRAP_V2_PREFIX, &[aad, enc, recipient, sender])
}

pub fn hpke_v3_info(aad: &[u8]) -> Result<Vec<u8>, HermesError> {
    require_aad_bound(aad)?;
    bounded_concat(HPKE_V3_PREFIX, &[aad])
}

pub fn hkdf_sha256(
    ikm: &[u8],
    salt: &[u8],
    info: &[u8],
    output_len: usize,
) -> Result<Zeroizing<Vec<u8>>, HermesError> {
    let aggregate = ikm
        .len()
        .checked_add(salt.len())
        .and_then(|total| total.checked_add(info.len()))
        .ok_or(HermesError::InputTooLarge)?;
    if aggregate > MAX_CRYPTO_INPUT_BYTES
        || salt.len() > MAX_AAD_BYTES
        || info.len() > MAX_AAD_BYTES
    {
        return Err(HermesError::InputTooLarge);
    }
    if output_len == 0 || output_len > 255 * 32 {
        return Err(HermesError::InvalidHkdfLength);
    }
    let hkdf = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut output = Zeroizing::new(vec![0_u8; output_len]);
    hkdf.expand(info, &mut output)
        .map_err(|_| HermesError::InvalidHkdfLength)?;
    Ok(output)
}

pub fn sha256(bytes: &[u8]) -> Result<Vec<u8>, HermesError> {
    if bytes.len() > MAX_CRYPTO_INPUT_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    Ok(Sha256::digest(bytes).to_vec())
}

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> Result<Vec<u8>, HermesError> {
    if key.len() > MAX_AAD_BYTES || data.len() > MAX_CRYPTO_INPUT_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    let mut mac =
        <Hmac<Sha256> as Mac>::new_from_slice(key).map_err(|_| HermesError::HmacFailure)?;
    mac.update(data);
    Ok(mac.finalize().into_bytes().to_vec())
}

// reason: explicit fields preserve the versioned ratchet wire contract across UniFFI.
#[allow(clippy::too_many_arguments, reason = "wire fields")]
pub fn ratchet_envelope_aad(
    associated_data: &[u8],
    algorithm: &str,
    session_id: &str,
    sender_device_id: &str,
    receiver_device_id: &str,
    ratchet_public_key_base64: &str,
    version: u64,
    previous_chain_length: u64,
    message_number: u64,
    epoch: u64,
) -> Result<Vec<u8>, HermesError> {
    if associated_data.len() > MAX_AAD_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    for component in [
        algorithm,
        session_id,
        sender_device_id,
        receiver_device_id,
        ratchet_public_key_base64,
    ] {
        validate_component(component)?;
    }
    let mut output = b"OpenBurnBar-HermesRatchet-v1-AAD".to_vec();
    for part in [
        associated_data,
        algorithm.as_bytes(),
        session_id.as_bytes(),
        sender_device_id.as_bytes(),
        receiver_device_id.as_bytes(),
        ratchet_public_key_base64.as_bytes(),
    ] {
        output.extend_from_slice(&(part.len() as u64).to_be_bytes());
        output.extend_from_slice(part);
    }
    for value in [version, previous_chain_length, message_number, epoch] {
        output.extend_from_slice(&value.to_be_bytes());
    }
    Ok(output)
}

pub fn ratchet_prekey_shared_secret(
    request: RatchetPrekeyRequest<'_>,
) -> Result<Zeroizing<Vec<u8>>, HermesError> {
    if [request.dh1, request.dh2, request.dh3]
        .iter()
        .any(|secret| secret.len() != 32)
    {
        return Err(HermesError::InvalidRatchetSharedSecretLength);
    }

    let mut info = Vec::from(RATCHET_PREKEY_KDF_DOMAIN);
    for part in [
        request.uid.as_bytes(),
        request.client_id.as_bytes(),
        RATCHET_CHAT_LANE.as_bytes(),
        request.initiator_role.as_bytes(),
    ] {
        append_length_prefixed(&mut info, part)?;
    }
    for encoded_key in [
        request.initiator_identity_public_key_base64,
        request.responder_identity_public_key_base64,
        request.initiator_signed_prekey_public_key_base64,
        request.responder_signed_prekey_public_key_base64,
        request.initiator_initial_ratchet_public_key_base64,
    ] {
        let key = BASE64
            .decode(encoded_key)
            .map_err(|_| HermesError::InvalidP256PublicKey)?;
        validate_p256_x963(&key)?;
        append_length_prefixed(&mut info, &key)?;
    }

    let mut input_key_material = Zeroizing::new(Vec::with_capacity(96));
    input_key_material.extend_from_slice(request.dh1);
    input_key_material.extend_from_slice(request.dh2);
    input_key_material.extend_from_slice(request.dh3);
    hkdf_sha256(&input_key_material, RATCHET_PREKEY_KDF_DOMAIN, &info, 32)
}

pub fn gateway_relay_safety_code(agent: &[u8], phone: &[u8]) -> Result<String, HermesError> {
    validate_p256_x963(agent)?;
    validate_p256_x963(phone)?;
    let (first, second) = if agent <= phone {
        (agent, phone)
    } else {
        (phone, agent)
    };
    let mut hasher = Sha256::new();
    hasher.update(first);
    hasher.update(second);
    let digest = hasher.finalize();
    Ok((0..16)
        .step_by(2)
        .map(|index| format!("{:02X}{:02X}", digest[index], digest[index + 1]))
        .collect::<Vec<_>>()
        .join(" "))
}

pub fn seal_base64(
    plaintext: &[u8],
    key: &[u8],
    aad: &[u8],
    nonce: &[u8],
) -> Result<String, HermesError> {
    Ok(BASE64.encode(seal_combined(plaintext, key, aad, nonce)?))
}

pub fn seal_combined(
    plaintext: &[u8],
    key: &[u8],
    aad: &[u8],
    nonce: &[u8],
) -> Result<Vec<u8>, HermesError> {
    if plaintext.len() > MAX_CRYPTO_INPUT_BYTES || aad.len() > MAX_AAD_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    let cipher = cipher(key)?;
    if nonce.len() != GCM_NONCE_LEN {
        return Err(HermesError::InvalidNonceLength);
    }
    let body = cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| HermesError::AuthenticationFailed)?;
    let mut combined = Vec::with_capacity(nonce.len() + body.len());
    combined.extend_from_slice(nonce);
    combined.extend_from_slice(&body);
    Ok(combined)
}

pub fn open_base64(ciphertext: &str, key: &[u8], aad: &[u8]) -> Result<Vec<u8>, HermesError> {
    if ciphertext.len() > MAX_BASE64_INPUT_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    let combined = BASE64
        .decode(ciphertext)
        .map_err(|_| HermesError::InvalidCiphertext)?;
    open_combined(&combined, key, aad)
}

pub fn open_combined(combined: &[u8], key: &[u8], aad: &[u8]) -> Result<Vec<u8>, HermesError> {
    if combined.len() > MAX_CRYPTO_INPUT_BYTES + GCM_NONCE_LEN + GCM_TAG_LEN
        || aad.len() > MAX_AAD_BYTES
    {
        return Err(HermesError::InputTooLarge);
    }
    if combined.len() < GCM_NONCE_LEN + GCM_TAG_LEN {
        return Err(HermesError::InvalidCiphertext);
    }
    let (nonce, body) = combined.split_at(GCM_NONCE_LEN);
    cipher(key)?
        .decrypt(Nonce::from_slice(nonce), Payload { msg: body, aad })
        .map_err(|_| HermesError::AuthenticationFailed)
}

fn cipher(key: &[u8]) -> Result<Aes256Gcm, HermesError> {
    if key.len() != AES_KEY_LEN {
        return Err(HermesError::InvalidKeyLength);
    }
    Aes256Gcm::new_from_slice(key).map_err(|_| HermesError::InvalidKeyLength)
}

fn bounded_concat(prefix: &[u8], parts: &[&[u8]]) -> Result<Vec<u8>, HermesError> {
    let capacity = parts.iter().try_fold(prefix.len(), |total, part| {
        total
            .checked_add(part.len())
            .ok_or(HermesError::InputTooLarge)
    })?;
    if capacity > MAX_CRYPTO_INPUT_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    let mut output = Vec::with_capacity(capacity);
    output.extend_from_slice(prefix);
    for part in parts {
        output.extend_from_slice(part);
    }
    Ok(output)
}

fn append_length_prefixed(output: &mut Vec<u8>, value: &[u8]) -> Result<(), HermesError> {
    let new_len = output
        .len()
        .checked_add(8)
        .and_then(|length| length.checked_add(value.len()))
        .ok_or(HermesError::InputTooLarge)?;
    if new_len > MAX_AAD_BYTES {
        return Err(HermesError::InputTooLarge);
    }
    output.extend_from_slice(&(value.len() as u64).to_be_bytes());
    output.extend_from_slice(value);
    Ok(())
}

fn validate_p256_x963(value: &[u8]) -> Result<(), HermesError> {
    if value.len() != P256_X963_PUBLIC_KEY_LEN || value.first() != Some(&0x04) {
        return Err(HermesError::InvalidP256PublicKey);
    }
    PublicKey::from_sec1_bytes(value)
        .map(|_| ())
        .map_err(|_| HermesError::InvalidP256PublicKey)
}

fn require_aad_bound(value: &[u8]) -> Result<(), HermesError> {
    if value.is_empty() {
        Err(HermesError::InvalidAadComponent)
    } else if value.len() > MAX_AAD_BYTES {
        Err(HermesError::InputTooLarge)
    } else {
        Ok(())
    }
}

fn validate_component(value: &str) -> Result<(), HermesError> {
    if value.is_empty()
        || value.len() > MAX_AAD_ARGUMENT_BYTES
        || value.bytes().any(|byte| byte <= 0x1f || byte == 0x7f)
    {
        Err(HermesError::InvalidAadComponent)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_vectors_are_stable() -> Result<(), HermesError> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/domain-core/hermes/v1/hermes-crypto-kat.json"
        ))
        .map_err(|_| HermesError::InvalidCiphertext)?;
        let request = aad(
            AadKind::Request,
            &["user-1".into(), "connection-2".into(), "request-3".into()],
        )?;
        assert_eq!(
            request,
            b"OpenBurnBar-HermesRelay-v1|request|user-1|connection-2|request-3"
        );
        let key = [0x11; 32];
        let nonce = [0x22; 12];
        let ciphertext = seal_base64(b"hello Hermes", &key, &request, &nonce)?;
        assert_eq!(open_base64(&ciphertext, &key, &request)?, b"hello Hermes");
        assert_eq!(
            ciphertext,
            fixture["aesGcm"]["ciphertextBase64"]
                .as_str()
                .ok_or(HermesError::InvalidCiphertext)?
        );
        let agent = BASE64
            .decode(
                fixture["safetyCode"]["agentPublicKeyBase64"]
                    .as_str()
                    .ok_or(HermesError::InvalidCiphertext)?,
            )
            .map_err(|_| HermesError::InvalidCiphertext)?;
        let phone = BASE64
            .decode(
                fixture["safetyCode"]["phonePublicKeyBase64"]
                    .as_str()
                    .ok_or(HermesError::InvalidCiphertext)?,
            )
            .map_err(|_| HermesError::InvalidCiphertext)?;
        assert_eq!(
            gateway_relay_safety_code(&agent, &phone)?,
            fixture["safetyCode"]["display"]
                .as_str()
                .ok_or(HermesError::InvalidCiphertext)?
        );
        Ok(())
    }

    #[test]
    fn rejects_wrong_aad_and_lengths() -> Result<(), HermesError> {
        assert_eq!(
            aad(AadKind::Request, &[]),
            Err(HermesError::InvalidAadArguments)
        );
        assert_eq!(
            aad(AadKind::Request, &["a|b".into(), "c".into(), "d".into()]),
            Err(HermesError::InvalidAadComponent)
        );
        assert_eq!(
            aad(AadKind::Request, &["a".into(), "".into(), "d".into()]),
            Err(HermesError::InvalidAadComponent)
        );
        assert_eq!(key_wrap_info_v1(b""), Err(HermesError::InvalidAadComponent));
        assert_ne!(
            aad(AadKind::Request, &["a".into(), "b".into(), "c".into()])?,
            aad(AadKind::Request, &["a".into(), "b".into(), "c2".into()])?
        );
        assert_eq!(
            seal_base64(b"x", &[0; 31], b"aad", &[0; 12]),
            Err(HermesError::InvalidKeyLength)
        );
        let sealed = seal_base64(b"x", &[0; 32], b"aad", &[0; 12])?;
        assert_eq!(
            open_base64(&sealed, &[0; 32], b"wrong"),
            Err(HermesError::AuthenticationFailed)
        );
        Ok(())
    }

    #[test]
    fn key_wrap_v2_rejects_ambiguous_or_off_curve_points() {
        let invalid = [0_u8; P256_X963_PUBLIC_KEY_LEN];
        assert_eq!(
            key_wrap_info_v2(b"aad", &invalid, &invalid, &invalid),
            Err(HermesError::InvalidP256PublicKey)
        );
    }

    #[test]
    fn allocation_heavy_transforms_reject_oversized_inputs() {
        let oversized_aad = vec![0_u8; MAX_AAD_BYTES + 1];
        assert_eq!(
            key_wrap_info_v1(&oversized_aad),
            Err(HermesError::InputTooLarge)
        );
        assert_eq!(
            hpke_v3_info(&oversized_aad),
            Err(HermesError::InputTooLarge)
        );
        assert_eq!(
            sha256(&vec![0_u8; MAX_CRYPTO_INPUT_BYTES + 1]),
            Err(HermesError::InputTooLarge)
        );
        assert_eq!(
            hmac_sha256(&[0_u8; 1], &vec![0_u8; MAX_CRYPTO_INPUT_BYTES + 1]),
            Err(HermesError::InputTooLarge)
        );
        assert_eq!(
            hkdf_sha256(&[0_u8; 1], &oversized_aad, b"info", 32),
            Err(HermesError::InputTooLarge)
        );
        assert_eq!(
            ratchet_envelope_aad(
                &oversized_aad,
                "algorithm",
                "session",
                "sender",
                "receiver",
                "key",
                1,
                0,
                0,
                0,
            ),
            Err(HermesError::InputTooLarge)
        );
        let oversized_base64 = "A".repeat(MAX_BASE64_INPUT_BYTES + 1);
        assert_eq!(
            open_base64(&oversized_base64, &[0_u8; AES_KEY_LEN], b"aad"),
            Err(HermesError::InputTooLarge)
        );
        assert_eq!(
            ratchet_envelope_aad(b"aad", "", "session", "sender", "receiver", "key", 1, 0, 0, 0),
            Err(HermesError::InvalidAadComponent)
        );
    }

    #[test]
    fn accepted_aad_tuple_encoding_is_injective() -> Result<(), HermesError> {
        let samples = ["alpha", "beta", "gamma", "delta"];
        let mut seen = std::collections::BTreeSet::new();
        for first in samples {
            for second in samples {
                for third in samples {
                    let encoded = aad(
                        AadKind::Request,
                        &[first.to_owned(), second.to_owned(), third.to_owned()],
                    )?;
                    assert!(seen.insert(encoded));
                }
            }
        }
        Ok(())
    }

    #[test]
    fn ratchet_wire_transforms_match_frozen_vectors() -> Result<(), HermesError> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/domain-core/hermes/v1/hermes-crypto-kat.json"
        ))
        .map_err(|_| HermesError::InvalidCiphertext)?;
        let aad = ratchet_envelope_aad(
            b"assoc",
            "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM",
            "session",
            "sender",
            "receiver",
            "cHVibGlj",
            1,
            2,
            3,
            4,
        )?;
        assert_eq!(
            hex(&aad),
            fixture["ratchet"]["envelopeAadHex"]
                .as_str()
                .ok_or(HermesError::InvalidCiphertext)?
        );
        let key = (0_u8..32).collect::<Vec<_>>();
        assert_eq!(
            hex(&hmac_sha256(&key, b"OpenBurnBar-HermesRatchet-v1-chain")?),
            fixture["ratchet"]["nextChainKeyHex"]
                .as_str()
                .ok_or(HermesError::InvalidCiphertext)?
        );
        assert_eq!(
            hex(&hmac_sha256(&key, b"OpenBurnBar-HermesRatchet-v1-message")?),
            fixture["ratchet"]["messageKeyHex"]
                .as_str()
                .ok_or(HermesError::InvalidCiphertext)?
        );
        let prekey = &fixture["ratchet"]["prekey"];
        let string = |name: &str| prekey[name].as_str().ok_or(HermesError::InvalidCiphertext);
        let shared_secret_chunks = prekey["sharedSecretHexChunks"]
            .as_array()
            .ok_or(HermesError::InvalidCiphertext)?;
        if shared_secret_chunks.len() != 2 {
            return Err(HermesError::InvalidCiphertext);
        }
        let shared_secret_hex = shared_secret_chunks
            .iter()
            .map(|chunk| {
                let chunk = chunk.as_str().ok_or(HermesError::InvalidCiphertext)?;
                if chunk.len() != 32 {
                    return Err(HermesError::InvalidCiphertext);
                }
                Ok(chunk)
            })
            .collect::<Result<String, HermesError>>()?;
        let dh1 = (0_u8..32).collect::<Vec<_>>();
        let dh2 = (32_u8..64).collect::<Vec<_>>();
        let dh3 = (64_u8..96).collect::<Vec<_>>();
        assert_eq!(
            hex(&ratchet_prekey_shared_secret(RatchetPrekeyRequest {
                dh1: &dh1,
                dh2: &dh2,
                dh3: &dh3,
                uid: string("uid")?,
                client_id: string("clientID")?,
                initiator_role: string("initiatorRole")?,
                initiator_identity_public_key_base64: string("initiatorIdentityPublicKeyBase64")?,
                responder_identity_public_key_base64: string("responderIdentityPublicKeyBase64")?,
                initiator_signed_prekey_public_key_base64: string(
                    "initiatorSignedPreKeyPublicKeyBase64"
                )?,
                responder_signed_prekey_public_key_base64: string(
                    "responderSignedPreKeyPublicKeyBase64"
                )?,
                initiator_initial_ratchet_public_key_base64: string(
                    "initiatorInitialRatchetPublicKeyBase64"
                )?,
            })?),
            shared_secret_hex
        );
        Ok(())
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}
