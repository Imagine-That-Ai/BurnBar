use std::fs::{File, Metadata, OpenOptions};
use std::io::Read;
use std::os::fd::OwnedFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use crate::auth::AuthorizedPeer;
use crate::error::{BrokerError, ErrorCode};
use crate::protocol::{AttestRequest, Attestation, Binding};
use base64ct::{Base64, Encoding};
use serde::Deserialize;
use sha2::{Digest, Sha256};

const ENROLLMENT_STATE_FILE: &str = "tpm-enrollment.json";
const MAX_ENROLLMENT_STATE_BYTES: u64 = 512 * 1024;
const MAX_AK_TPM_BASE64_BYTES: usize = 64 * 1024;
const MAX_EK_TPM_BASE64_BYTES: usize = 64 * 1024;
const MAX_EK_CERTIFICATE_BASE64_BYTES: usize = 128 * 1024;

#[derive(Debug)]
pub struct AttestationResult {
    pub attestation: Attestation,
    pub evidence_bundle: OwnedFd,
}

pub trait AttestationBackend: Send + Sync {
    fn describe(&self, peer: &AuthorizedPeer) -> Result<Binding, BrokerError>;

    fn attest(
        &self,
        request: &AttestRequest,
        peer: &AuthorizedPeer,
    ) -> Result<AttestationResult, BrokerError>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct UnsupportedAttestationBackend;

impl AttestationBackend for UnsupportedAttestationBackend {
    fn describe(&self, _peer: &AuthorizedPeer) -> Result<Binding, BrokerError> {
        Err(unsupported())
    }

    fn attest(
        &self,
        _request: &AttestRequest,
        _peer: &AuthorizedPeer,
    ) -> Result<AttestationResult, BrokerError> {
        Err(unsupported())
    }
}

const fn unsupported() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationUnsupported,
        "TPM2 and IMA attestation is not configured on this broker",
        false,
    )
}

#[derive(Clone, Debug)]
pub struct TpmImaAttestationBackend {
    enrollment_state_path: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawEnrollmentState {
    schema_version: u32,
    device_id: String,
    agent_id: String,
    ak_tpm_base64: String,
    ek_tpm_base64: String,
    ek_certificate_base64: String,
    enrolled_at_millis: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct EnrollmentState {
    device_id: String,
}

#[derive(Clone, Copy, Debug)]
struct EnrollmentFileIdentity {
    is_regular: bool,
    uid: u32,
    gid: u32,
    mode: u32,
    links: u64,
    size: u64,
}

impl From<&Metadata> for EnrollmentFileIdentity {
    fn from(metadata: &Metadata) -> Self {
        Self {
            is_regular: metadata.file_type().is_file(),
            uid: metadata.uid(),
            gid: metadata.gid(),
            mode: metadata.mode() & 0o7777,
            links: metadata.nlink(),
            size: metadata.len(),
        }
    }
}

impl TpmImaAttestationBackend {
    pub fn new(state_dir: PathBuf) -> Result<Self, BrokerError> {
        if !state_dir.is_absolute() {
            return Err(BrokerError::new(
                ErrorCode::Internal,
                "attestation state directory must be absolute",
                false,
            ));
        }
        Ok(Self {
            enrollment_state_path: state_dir.join(ENROLLMENT_STATE_FILE),
        })
    }

    fn load_enrollment_state(&self) -> Result<EnrollmentState, BrokerError> {
        let bytes = read_enrollment_state_file(&self.enrollment_state_path)?;
        parse_enrollment_state(&bytes)
    }
}

impl AttestationBackend for TpmImaAttestationBackend {
    fn describe(&self, peer: &AuthorizedPeer) -> Result<Binding, BrokerError> {
        let enrollment = self.load_enrollment_state()?;
        Ok(binding_for_enrollment(peer, &enrollment))
    }

    fn attest(
        &self,
        _request: &AttestRequest,
        _peer: &AuthorizedPeer,
    ) -> Result<AttestationResult, BrokerError> {
        Err(BrokerError::new(
            ErrorCode::AttestationUnsupported,
            "TPM2 quote collection is not implemented on this broker",
            false,
        ))
    }
}

fn binding_for_enrollment(peer: &AuthorizedPeer, enrollment: &EnrollmentState) -> Binding {
    let release = &peer.installed_release;
    Binding {
        app_id: release.firebase_app_id.clone(),
        device_id: enrollment.device_id.clone(),
        app_version: release.app_version.clone(),
        architecture: release.architecture.clone(),
        release_digest_sha256: release.release_digest_sha256.clone(),
        policy_id: release.policy_id.clone(),
        attestation_kind: release.attestation_kind.clone(),
    }
}

fn read_enrollment_state_file(path: &Path) -> Result<Vec<u8>, BrokerError> {
    let file = open_no_follow(path).map_err(|_| enrollment_unavailable())?;
    let metadata = file.metadata().map_err(|_| enrollment_unavailable())?;
    validate_enrollment_file_identity(EnrollmentFileIdentity::from(&metadata))?;
    let expected_size = usize::try_from(metadata.len()).map_err(|_| enrollment_unavailable())?;
    let mut bytes = Vec::with_capacity(expected_size);
    file.take(MAX_ENROLLMENT_STATE_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| enrollment_unavailable())?;
    if bytes.len() != expected_size {
        return Err(enrollment_unavailable());
    }
    Ok(bytes)
}

fn open_no_follow(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
}

fn validate_enrollment_file_identity(identity: EnrollmentFileIdentity) -> Result<(), BrokerError> {
    if !identity.is_regular
        || identity.uid != 0
        || identity.gid != 0
        || !matches!(identity.mode, 0o400 | 0o600)
        || identity.links != 1
        || identity.size == 0
        || identity.size > MAX_ENROLLMENT_STATE_BYTES
    {
        return Err(enrollment_unavailable());
    }
    Ok(())
}

fn parse_enrollment_state(bytes: &[u8]) -> Result<EnrollmentState, BrokerError> {
    let raw: RawEnrollmentState =
        serde_json::from_slice(bytes).map_err(|_| enrollment_unavailable())?;
    if raw.schema_version != 1
        || !valid_device_id(&raw.device_id)
        || !valid_uuid(&raw.agent_id)
        || raw.enrolled_at_millis <= 0
    {
        return Err(enrollment_unavailable());
    }
    let ak = decode_canonical_base64(&raw.ak_tpm_base64, MAX_AK_TPM_BASE64_BYTES)?;
    let _ek = decode_canonical_base64(&raw.ek_tpm_base64, MAX_EK_TPM_BASE64_BYTES)?;
    let _ek_certificate =
        decode_canonical_base64(&raw.ek_certificate_base64, MAX_EK_CERTIFICATE_BASE64_BYTES)?;
    if device_id_for_ak(&ak) != raw.device_id {
        return Err(enrollment_unavailable());
    }
    Ok(EnrollmentState {
        device_id: raw.device_id,
    })
}

fn decode_canonical_base64(value: &str, max_bytes: usize) -> Result<Vec<u8>, BrokerError> {
    if value.is_empty() || value.len() > max_bytes {
        return Err(enrollment_unavailable());
    }
    let mut decoded = vec![0_u8; value.len().saturating_mul(3) / 4 + 3];
    let decoded_len = {
        let slice = Base64::decode(value, &mut decoded).map_err(|_| enrollment_unavailable())?;
        slice.len()
    };
    decoded.truncate(decoded_len);
    if decoded.is_empty() {
        return Err(enrollment_unavailable());
    }
    let mut canonical = vec![0_u8; value.len().saturating_add(4)];
    let encoded = Base64::encode(&decoded, &mut canonical).map_err(|_| enrollment_unavailable())?;
    if encoded != value {
        return Err(enrollment_unavailable());
    }
    Ok(decoded)
}

fn device_id_for_ak(ak_tpm: &[u8]) -> String {
    format!("ak-sha256:{:x}", Sha256::digest(ak_tpm))
}

fn valid_device_id(value: &str) -> bool {
    value
        .strip_prefix("ak-sha256:")
        .is_some_and(|digest| valid_lower_hex(digest, 64))
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')
            }
        })
}

fn valid_lower_hex(value: &str, bytes: usize) -> bool {
    value.len() == bytes
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

const fn enrollment_unavailable() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationUnsupported,
        "TPM2 enrollment state is unavailable on this broker",
        false,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{InstalledReleaseIdentity, PeerCredentials};
    use crate::protocol::ATTESTATION_KIND;

    fn enrollment_json(ak_base64: &str, device_id: &str) -> Vec<u8> {
        format!(
            r#"{{"schemaVersion":1,"deviceId":"{device_id}","agentId":"00000000-0000-8000-8000-000000000000","akTpmBase64":"{ak_base64}","ekTpmBase64":"ZWs=","ekCertificateBase64":"Y2VydA==","enrolledAtMillis":1700000000000}}"#
        )
        .into_bytes()
    }

    fn peer() -> AuthorizedPeer {
        AuthorizedPeer {
            credentials: PeerCredentials {
                pid: 10,
                uid: 1_000,
                gid: 1_000,
            },
            executable_sha256: "e".repeat(64),
            installed_release: InstalledReleaseIdentity {
                firebase_app_id: "1:123456789:web:abcdef0123456789".to_owned(),
                app_version: "1.2.3".to_owned(),
                architecture: "x86_64".to_owned(),
                release_digest_sha256: "a".repeat(64),
                policy_id: "openburnbar-linux-tpm2-ima-v1".to_owned(),
                attestation_kind: ATTESTATION_KIND.to_owned(),
            },
        }
    }

    #[test]
    fn parses_enrollment_state_and_binds_device_id_to_ak() {
        let ak_base64 = "YWstdHBtMmI=";
        let device_id = device_id_for_ak(b"ak-tpm2b");
        let parsed = parse_enrollment_state(&enrollment_json(ak_base64, &device_id));
        assert_eq!(
            parsed.ok(),
            Some(EnrollmentState {
                device_id: device_id.clone()
            })
        );

        let mismatched = parse_enrollment_state(&enrollment_json(
            ak_base64,
            &format!("ak-sha256:{}", "0".repeat(64)),
        ));
        assert_eq!(
            mismatched.err().map(|error| error.code()),
            Some(ErrorCode::AttestationUnsupported)
        );
    }

    #[test]
    fn rejects_noncanonical_or_loose_enrollment_json() {
        let ak_base64 = "YWstdHBtMmI=";
        let device_id = device_id_for_ak(b"ak-tpm2b");
        let mut value: serde_json::Value =
            serde_json::from_slice(&enrollment_json(ak_base64, &device_id)).unwrap_or_default();
        value["extra"] = serde_json::json!(true);
        assert_eq!(
            parse_enrollment_state(&serde_json::to_vec(&value).unwrap_or_default())
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::AttestationUnsupported)
        );

        let noncanonical = enrollment_json("AB==", &device_id);
        assert_eq!(
            parse_enrollment_state(&noncanonical)
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::AttestationUnsupported)
        );
    }

    #[test]
    fn enrollment_file_identity_requires_private_root_owned_regular_file() {
        let valid = EnrollmentFileIdentity {
            is_regular: true,
            uid: 0,
            gid: 0,
            mode: 0o600,
            links: 1,
            size: 1,
        };
        assert!(validate_enrollment_file_identity(valid).is_ok());
        for invalid in [
            EnrollmentFileIdentity {
                mode: 0o644,
                ..valid
            },
            EnrollmentFileIdentity { uid: 1, ..valid },
            EnrollmentFileIdentity { gid: 1, ..valid },
            EnrollmentFileIdentity { links: 2, ..valid },
            EnrollmentFileIdentity { size: 0, ..valid },
            EnrollmentFileIdentity {
                size: MAX_ENROLLMENT_STATE_BYTES + 1,
                ..valid
            },
        ] {
            assert_eq!(
                validate_enrollment_file_identity(invalid)
                    .err()
                    .map(|error| error.code()),
                Some(ErrorCode::AttestationUnsupported)
            );
        }
    }

    #[test]
    fn binding_uses_peer_release_and_enrolled_device() {
        let enrollment = EnrollmentState {
            device_id: "ak-sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                .to_owned(),
        };
        let binding = binding_for_enrollment(&peer(), &enrollment);
        assert_eq!(binding.app_id, "1:123456789:web:abcdef0123456789");
        assert_eq!(binding.device_id, enrollment.device_id);
        assert_eq!(binding.app_version, "1.2.3");
        assert_eq!(binding.architecture, "x86_64");
        assert_eq!(binding.release_digest_sha256, "a".repeat(64));
        assert_eq!(binding.policy_id, "openburnbar-linux-tpm2-ima-v1");
        assert_eq!(binding.attestation_kind, ATTESTATION_KIND);
    }
}
