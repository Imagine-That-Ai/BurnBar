use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

const AAD_PREFIX: &str = "OpenBurnBar-HermesRelay-v1";
const KEY_WRAP_V1_PREFIX: &[u8] = b"OpenBurnBar-HermesRelay-KeyWrap-v1|";
const KEY_WRAP_V2_PREFIX: &[u8] = b"OpenBurnBar-HermesRelay-KeyWrap-v2|";
const HPKE_V3_PREFIX: &[u8] = b"OpenBurnBar-HermesRelay-HPKE-v3|";
const AES_KEY_LEN: usize = 32;
const GCM_NONCE_LEN: usize = 12;
const GCM_TAG_LEN: usize = 16;

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
}

pub fn aad(kind: AadKind, arguments: &[String]) -> Result<Vec<u8>, HermesError> {
    if arguments.len() != kind.argument_count() {
        return Err(HermesError::InvalidAadArguments);
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

pub fn key_wrap_info_v1(aad: &[u8]) -> Vec<u8> {
    concat(KEY_WRAP_V1_PREFIX, &[aad])
}

pub fn key_wrap_info_v2(aad: &[u8], enc: &[u8], recipient: &[u8], sender: &[u8]) -> Vec<u8> {
    concat(KEY_WRAP_V2_PREFIX, &[aad, enc, recipient, sender])
}

pub fn hpke_v3_info(aad: &[u8]) -> Vec<u8> {
    concat(HPKE_V3_PREFIX, &[aad])
}

pub fn hkdf_sha256(
    ikm: &[u8],
    salt: &[u8],
    info: &[u8],
    output_len: usize,
) -> Result<Zeroizing<Vec<u8>>, HermesError> {
    if output_len == 0 || output_len > 255 * 32 {
        return Err(HermesError::InvalidHkdfLength);
    }
    let hkdf = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut output = Zeroizing::new(vec![0_u8; output_len]);
    hkdf.expand(info, &mut output)
        .map_err(|_| HermesError::InvalidHkdfLength)?;
    Ok(output)
}

pub fn sha256(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> Result<Vec<u8>, HermesError> {
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
) -> Vec<u8> {
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
    output
}

pub fn gateway_relay_safety_code(agent: &[u8], phone: &[u8]) -> String {
    let (first, second) = if agent <= phone {
        (agent, phone)
    } else {
        (phone, agent)
    };
    let mut hasher = Sha256::new();
    hasher.update(first);
    hasher.update(second);
    let digest = hasher.finalize();
    (0..16)
        .step_by(2)
        .map(|index| format!("{:02X}{:02X}", digest[index], digest[index + 1]))
        .collect::<Vec<_>>()
        .join(" ")
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
    let combined = BASE64
        .decode(ciphertext)
        .map_err(|_| HermesError::InvalidCiphertext)?;
    open_combined(&combined, key, aad)
}

pub fn open_combined(combined: &[u8], key: &[u8], aad: &[u8]) -> Result<Vec<u8>, HermesError> {
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

fn concat(prefix: &[u8], parts: &[&[u8]]) -> Vec<u8> {
    let capacity = prefix.len() + parts.iter().map(|part| part.len()).sum::<usize>();
    let mut output = Vec::with_capacity(capacity);
    output.extend_from_slice(prefix);
    for part in parts {
        output.extend_from_slice(part);
    }
    output
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
        Ok(())
    }

    #[test]
    fn rejects_wrong_aad_and_lengths() -> Result<(), HermesError> {
        assert_eq!(
            aad(AadKind::Request, &[]),
            Err(HermesError::InvalidAadArguments)
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
        );
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
        Ok(())
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}
