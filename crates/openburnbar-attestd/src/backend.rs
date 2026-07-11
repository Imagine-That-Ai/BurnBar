use std::fs::{File, Metadata, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
#[cfg(all(test, target_os = "linux"))]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::auth::AuthorizedPeer;
use crate::error::{BrokerError, ErrorCode};
use crate::protocol::{
    qualifying_data_sha256, AttestRequest, Attestation, Binding, EvidenceBundle, QuoteEvidence,
    ATTESTATION_KIND, EVIDENCE_BUNDLE_FORMAT, MAX_EVIDENCE_BUNDLE_BYTES,
};
use base64ct::{Base64, Encoding};
use serde::Deserialize;
use sha2::{Digest, Sha256};

const ENROLLMENT_STATE_FILE: &str = "tpm-enrollment.json";
const AK_CONTEXT_FILE: &str = "ak.ctx";
const TPM2_QUOTE_PATH: &str = "/usr/bin/tpm2_quote";
const IMA_MEASUREMENTS_PATH: &str = "/sys/kernel/security/ima/ascii_runtime_measurements";
const MEASURED_BOOT_LOG_PATHS: [&str; 2] = [
    "/sys/kernel/security/tpm0/binary_bios_measurements",
    "/sys/kernel/security/tpmrm0/binary_bios_measurements",
];
const MAX_ENROLLMENT_STATE_BYTES: u64 = 512 * 1024;
const MAX_AK_TPM_BASE64_BYTES: usize = 64 * 1024;
const MAX_EK_TPM_BASE64_BYTES: usize = 64 * 1024;
const MAX_EK_CERTIFICATE_BASE64_BYTES: usize = 128 * 1024;
const MAX_QUOTE_ATTESTATION_BYTES: usize = 12 * 1024;
const MAX_QUOTE_SIGNATURE_BYTES: usize = 3 * 1024;
const MAX_QUOTE_PCR_VALUES_BYTES: usize = 12 * 1024;
const MAX_INSTALLED_MANIFEST_BYTES: usize = 1024 * 1024;
const MAX_INSTALLED_MANIFEST_SIGNATURE_BYTES: usize = 64;
const EVIDENCE_MAGIC: &[u8; 8] = b"OBBATST1";
const EVIDENCE_PREFIX_BYTES: usize = 12;
const MAX_EVIDENCE_HEADER_BYTES: usize = 16_384;
const TPM_QUOTE_TIMEOUT: Duration = Duration::from_secs(30);
static TPM2_QUOTE_SPAWN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
#[cfg(all(test, target_os = "linux"))]
static TEST_TEMP_DIR_COUNTER: AtomicU64 = AtomicU64::new(0);

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
    ak_context_path: PathBuf,
    manifest_path: PathBuf,
    manifest_signature_path: PathBuf,
    ima_measurements_path: PathBuf,
    measured_boot_log_paths: Vec<PathBuf>,
    tpm2_quote_path: PathBuf,
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

#[derive(Debug)]
struct EvidenceRecord {
    kind: &'static str,
    bytes: Vec<u8>,
}

#[derive(Debug)]
struct TpmQuote {
    attestation: Vec<u8>,
    signature: Vec<u8>,
    pcr_values: Vec<u8>,
}

struct Tpm2QuoteInvocation<'a> {
    tpm2_quote_path: &'a Path,
    ak_context_path: &'a Path,
    qualifying_data_sha256: &'a str,
    message_fd: i32,
    signature_fd: i32,
    pcr_fd: i32,
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
    pub fn new(
        state_dir: PathBuf,
        manifest_path: PathBuf,
        manifest_signature_path: PathBuf,
    ) -> Result<Self, BrokerError> {
        if !state_dir.is_absolute() {
            return Err(BrokerError::new(
                ErrorCode::Internal,
                "attestation state directory must be absolute",
                false,
            ));
        }
        if !manifest_path.is_absolute() || !manifest_signature_path.is_absolute() {
            return Err(BrokerError::new(
                ErrorCode::Internal,
                "attestation manifest paths must be absolute",
                false,
            ));
        }
        Self::with_paths(
            state_dir.join(ENROLLMENT_STATE_FILE),
            state_dir.join(AK_CONTEXT_FILE),
            manifest_path,
            manifest_signature_path,
            PathBuf::from(IMA_MEASUREMENTS_PATH),
            MEASURED_BOOT_LOG_PATHS.iter().map(PathBuf::from).collect(),
            PathBuf::from(TPM2_QUOTE_PATH),
        )
    }

    fn with_paths(
        enrollment_state_path: PathBuf,
        ak_context_path: PathBuf,
        manifest_path: PathBuf,
        manifest_signature_path: PathBuf,
        ima_measurements_path: PathBuf,
        measured_boot_log_paths: Vec<PathBuf>,
        tpm2_quote_path: PathBuf,
    ) -> Result<Self, BrokerError> {
        if !enrollment_state_path.is_absolute()
            || !ak_context_path.is_absolute()
            || !manifest_path.is_absolute()
            || !manifest_signature_path.is_absolute()
            || !ima_measurements_path.is_absolute()
            || measured_boot_log_paths
                .iter()
                .any(|path| !path.is_absolute())
            || !tpm2_quote_path.is_absolute()
        {
            return Err(BrokerError::new(
                ErrorCode::Internal,
                "attestation backend paths must be absolute",
                false,
            ));
        }
        Ok(Self {
            enrollment_state_path,
            ak_context_path,
            manifest_path,
            manifest_signature_path,
            ima_measurements_path,
            measured_boot_log_paths,
            tpm2_quote_path,
        })
    }

    fn load_enrollment_state(&self) -> Result<EnrollmentState, BrokerError> {
        let bytes = read_enrollment_state_file(&self.enrollment_state_path)?;
        parse_enrollment_state(&bytes)
    }

    fn collect_tpm_quote(&self, qualifying_data_sha256: &str) -> Result<TpmQuote, BrokerError> {
        validate_private_state_file(&self.ak_context_path)?;
        let mut message = create_quote_output_memfd("openburnbar-tpm-quote-attest")?;
        let mut signature = create_quote_output_memfd("openburnbar-tpm-quote-signature")?;
        let mut pcr_values = create_quote_output_memfd("openburnbar-tpm-quote-pcr-values")?;
        run_tpm2_quote(&Tpm2QuoteInvocation {
            tpm2_quote_path: &self.tpm2_quote_path,
            ak_context_path: &self.ak_context_path,
            qualifying_data_sha256,
            message_fd: message.as_raw_fd(),
            signature_fd: signature.as_raw_fd(),
            pcr_fd: pcr_values.as_raw_fd(),
        })?;
        Ok(TpmQuote {
            attestation: read_required_memfd(
                &mut message,
                MAX_QUOTE_ATTESTATION_BYTES,
                quote_collection_failed,
            )?,
            signature: read_required_memfd(
                &mut signature,
                MAX_QUOTE_SIGNATURE_BYTES,
                quote_collection_failed,
            )?,
            pcr_values: read_required_memfd(
                &mut pcr_values,
                MAX_QUOTE_PCR_VALUES_BYTES,
                quote_collection_failed,
            )?,
        })
    }

    fn build_evidence_bundle(&self, binding: &Binding) -> Result<Vec<u8>, BrokerError> {
        let installed_manifest = read_required_file(
            &self.manifest_path,
            MAX_INSTALLED_MANIFEST_BYTES,
            evidence_unavailable,
        )?;
        if sha256_hex(&installed_manifest) != binding.release_digest_sha256 {
            return Err(evidence_unavailable());
        }
        build_evidence_bundle([
            EvidenceRecord {
                kind: "ima_ascii_runtime_measurements",
                bytes: read_ima_measurements(&self.ima_measurements_path)?,
            },
            EvidenceRecord {
                kind: "uefi_binary_bios_measurements",
                bytes: read_first_available_measured_boot_log(&self.measured_boot_log_paths)?,
            },
            EvidenceRecord {
                kind: "installed_manifest",
                bytes: installed_manifest,
            },
            EvidenceRecord {
                kind: "installed_manifest_signature",
                bytes: read_exact_file(
                    &self.manifest_signature_path,
                    MAX_INSTALLED_MANIFEST_SIGNATURE_BYTES,
                    evidence_unavailable,
                )?,
            },
        ])
    }
}

impl AttestationBackend for TpmImaAttestationBackend {
    fn describe(&self, peer: &AuthorizedPeer) -> Result<Binding, BrokerError> {
        let enrollment = self.load_enrollment_state()?;
        Ok(binding_for_enrollment(peer, &enrollment))
    }

    fn attest(
        &self,
        request: &AttestRequest,
        peer: &AuthorizedPeer,
    ) -> Result<AttestationResult, BrokerError> {
        let enrollment = self.load_enrollment_state()?;
        let binding = binding_for_enrollment(peer, &enrollment);
        if request.binding != binding {
            return Err(BrokerError::new(
                ErrorCode::InvalidRequest,
                "attestation binding does not match the installed release or enrolled device",
                false,
            ));
        }
        let qualifying_data = qualifying_data_sha256(&request.challenge.challenge, &binding)?;
        let quote = self.collect_tpm_quote(&qualifying_data)?;
        let evidence_bundle_bytes = self.build_evidence_bundle(&binding)?;
        let evidence_bundle = EvidenceBundle {
            descriptor_index: 0,
            format: EVIDENCE_BUNDLE_FORMAT.to_owned(),
            byte_length: evidence_bundle_bytes.len() as u64,
            sha256: sha256_hex(&evidence_bundle_bytes),
        };
        Ok(AttestationResult {
            attestation: Attestation {
                challenge_id: request.challenge.challenge_id.clone(),
                challenge: request.challenge.challenge.clone(),
                kind: ATTESTATION_KIND.to_owned(),
                evidence: QuoteEvidence {
                    schema_version: 1,
                    device_id: binding.device_id,
                    quote_attestation_base64: encode_base64(
                        &quote.attestation,
                        16_384,
                        quote_collection_failed,
                    )?,
                    quote_signature_base64: encode_base64(
                        &quote.signature,
                        4_096,
                        quote_collection_failed,
                    )?,
                    quote_pcr_values_base64: encode_base64(
                        &quote.pcr_values,
                        16_384,
                        quote_collection_failed,
                    )?,
                    pcr_bank: "sha256".to_owned(),
                    pcr_selection: [0, 2, 4, 7, 10],
                    qualifying_data_sha256: qualifying_data,
                },
                evidence_bundle,
            },
            evidence_bundle: create_evidence_fd(&evidence_bundle_bytes)?,
        })
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

fn validate_private_state_file(path: &Path) -> Result<(), BrokerError> {
    let file = open_no_follow(path).map_err(|_| enrollment_unavailable())?;
    let metadata = file.metadata().map_err(|_| enrollment_unavailable())?;
    validate_enrollment_file_identity(EnrollmentFileIdentity::from(&metadata))
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
    format!("ak-sha256:{}", sha256_hex(ak_tpm))
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn read_required_file(
    path: &Path,
    max_bytes: usize,
    error: fn() -> BrokerError,
) -> Result<Vec<u8>, BrokerError> {
    let file = open_no_follow(path).map_err(|_| error())?;
    read_bounded(file, max_bytes, error)
}

fn read_exact_file(
    path: &Path,
    expected_bytes: usize,
    error: fn() -> BrokerError,
) -> Result<Vec<u8>, BrokerError> {
    let bytes = read_required_file(path, expected_bytes, error)?;
    if bytes.len() != expected_bytes {
        return Err(error());
    }
    Ok(bytes)
}

fn read_bounded(
    file: File,
    max_bytes: usize,
    error: fn() -> BrokerError,
) -> Result<Vec<u8>, BrokerError> {
    let mut bytes = Vec::new();
    file.take(max_bytes.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| error())?;
    if bytes.is_empty() || bytes.len() > max_bytes {
        return Err(error());
    }
    Ok(bytes)
}

fn read_required_memfd(
    file: &mut File,
    max_bytes: usize,
    error: fn() -> BrokerError,
) -> Result<Vec<u8>, BrokerError> {
    file.seek(SeekFrom::Start(0)).map_err(|_| error())?;
    let cloned = file.try_clone().map_err(|_| error())?;
    read_bounded(cloned, max_bytes, error)
}

fn read_ima_measurements(path: &Path) -> Result<Vec<u8>, BrokerError> {
    let bytes = read_required_file(
        path,
        MAX_EVIDENCE_BUNDLE_BYTES as usize,
        evidence_unavailable,
    )?;
    if std::str::from_utf8(&bytes).is_err() || bytes.contains(&0) {
        return Err(evidence_unavailable());
    }
    Ok(bytes)
}

fn read_first_available_measured_boot_log(paths: &[PathBuf]) -> Result<Vec<u8>, BrokerError> {
    for path in paths {
        if let Ok(bytes) = read_required_file(
            path,
            MAX_EVIDENCE_BUNDLE_BYTES as usize,
            evidence_unavailable,
        ) {
            return Ok(bytes);
        }
    }
    Err(evidence_unavailable())
}

fn build_evidence_bundle(records: [EvidenceRecord; 4]) -> Result<Vec<u8>, BrokerError> {
    let mut offsets = [0_usize; 4];
    for _iteration in 0..8 {
        let header = evidence_header(&records, &offsets);
        if header.len() > MAX_EVIDENCE_HEADER_BYTES {
            return Err(evidence_unavailable());
        }
        let next_offsets = evidence_offsets(&records, header.len())?;
        if next_offsets == offsets {
            return evidence_bundle_with_header(&records, header, offsets);
        }
        offsets = next_offsets;
    }
    Err(BrokerError::new(
        ErrorCode::Internal,
        "attestation evidence header did not converge",
        false,
    ))
}

fn evidence_offsets(
    records: &[EvidenceRecord; 4],
    header_len: usize,
) -> Result<[usize; 4], BrokerError> {
    let mut offsets = [0_usize; 4];
    let mut cursor = EVIDENCE_PREFIX_BYTES
        .checked_add(header_len)
        .ok_or_else(evidence_unavailable)?;
    for (index, record) in records.iter().enumerate() {
        if record.bytes.is_empty() {
            return Err(evidence_unavailable());
        }
        offsets[index] = cursor;
        cursor = cursor
            .checked_add(record.bytes.len())
            .ok_or_else(evidence_unavailable)?;
    }
    if cursor > MAX_EVIDENCE_BUNDLE_BYTES as usize {
        return Err(evidence_unavailable());
    }
    Ok(offsets)
}

fn evidence_bundle_with_header(
    records: &[EvidenceRecord; 4],
    header: String,
    offsets: [usize; 4],
) -> Result<Vec<u8>, BrokerError> {
    let stable_offsets = evidence_offsets(records, header.len())?;
    if stable_offsets != offsets {
        return Err(BrokerError::new(
            ErrorCode::Internal,
            "attestation evidence header offsets are unstable",
            false,
        ));
    }
    let header_len = u32::try_from(header.len()).map_err(|_| evidence_unavailable())?;
    let total_len = EVIDENCE_PREFIX_BYTES
        .checked_add(header.len())
        .and_then(|size| {
            records.iter().try_fold(size, |cursor, record| {
                cursor.checked_add(record.bytes.len())
            })
        })
        .ok_or_else(evidence_unavailable)?;
    if total_len > MAX_EVIDENCE_BUNDLE_BYTES as usize {
        return Err(evidence_unavailable());
    }
    let mut bundle = Vec::with_capacity(total_len);
    bundle.extend_from_slice(EVIDENCE_MAGIC);
    bundle.extend_from_slice(&header_len.to_be_bytes());
    bundle.extend_from_slice(header.as_bytes());
    for record in records {
        bundle.extend_from_slice(&record.bytes);
    }
    Ok(bundle)
}

fn evidence_header(records: &[EvidenceRecord; 4], offsets: &[usize; 4]) -> String {
    let rows = records
        .iter()
        .zip(offsets.iter())
        .map(|(record, offset)| {
            format!(
                r#"{{"byteLength":{},"kind":"{}","offset":{},"sha256":"{}"}}"#,
                record.bytes.len(),
                record.kind,
                offset,
                sha256_hex(&record.bytes)
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!(r#"{{"records":[{rows}],"schemaVersion":1}}"#)
}

#[cfg(target_os = "linux")]
fn create_quote_output_memfd(name: &str) -> Result<File, BrokerError> {
    crate::linux::create_unsealed_memfd(name)
}

#[cfg(not(target_os = "linux"))]
fn create_quote_output_memfd(_name: &str) -> Result<File, BrokerError> {
    Err(evidence_unavailable())
}

fn run_tpm2_quote(invocation: &Tpm2QuoteInvocation<'_>) -> Result<(), BrokerError> {
    let fds = [
        invocation.message_fd,
        invocation.signature_fd,
        invocation.pcr_fd,
    ];
    let message_path = format!("/proc/self/fd/{}", invocation.message_fd);
    let signature_path = format!("/proc/self/fd/{}", invocation.signature_fd);
    let pcr_path = format!("/proc/self/fd/{}", invocation.pcr_fd);
    let spawn_lock = TPM2_QUOTE_SPAWN_LOCK.get_or_init(|| Mutex::new(()));
    let guard = spawn_lock.lock().map_err(|_| quote_collection_failed())?;
    set_quote_output_fds_cloexec(&fds, false)?;
    let spawn_result = Command::new(invocation.tpm2_quote_path)
        .arg("-Q")
        .arg("-c")
        .arg(invocation.ak_context_path)
        .arg("-l")
        .arg("sha256:0,2,4,7,10")
        .arg("-q")
        .arg(invocation.qualifying_data_sha256)
        .arg("-m")
        .arg(&message_path)
        .arg("-s")
        .arg(&signature_path)
        .arg("-f")
        .arg("tss")
        .arg("-F")
        .arg("serialized")
        .arg("-g")
        .arg("sha256")
        .arg("-o")
        .arg(&pcr_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let restore_result = set_quote_output_fds_cloexec(&fds, true);
    drop(guard);
    restore_result?;
    let mut child = spawn_result.map_err(|_| enrollment_unavailable())?;
    let deadline = Instant::now() + TPM_QUOTE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(_status)) => return Err(quote_collection_failed()),
            Ok(None) if Instant::now() >= deadline => {
                let _kill_result = child.kill();
                let _wait_result = child.wait();
                return Err(quote_collection_failed());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => return Err(quote_collection_failed()),
        }
    }
}

#[cfg(target_os = "linux")]
fn set_quote_output_fds_cloexec(fds: &[i32], cloexec: bool) -> Result<(), BrokerError> {
    for fd in fds {
        crate::linux::set_descriptor_cloexec(*fd, cloexec)?;
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn set_quote_output_fds_cloexec(_fds: &[i32], _cloexec: bool) -> Result<(), BrokerError> {
    Err(evidence_unavailable())
}

fn encode_base64(
    bytes: &[u8],
    max_len: usize,
    error: fn() -> BrokerError,
) -> Result<String, BrokerError> {
    if bytes.is_empty() {
        return Err(error());
    }
    let mut encoded = vec![0_u8; bytes.len().saturating_add(2) / 3 * 4 + 4];
    let value = Base64::encode(bytes, &mut encoded).map_err(|_| error())?;
    if value.len() > max_len {
        return Err(error());
    }
    Ok(value.to_owned())
}

#[cfg(target_os = "linux")]
fn create_evidence_fd(bytes: &[u8]) -> Result<OwnedFd, BrokerError> {
    crate::linux::create_sealed_memfd(bytes)
}

#[cfg(not(target_os = "linux"))]
fn create_evidence_fd(_bytes: &[u8]) -> Result<OwnedFd, BrokerError> {
    Err(BrokerError::new(
        ErrorCode::AttestationUnsupported,
        "TPM2 and IMA attestation is available only on Linux",
        false,
    ))
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

const fn evidence_unavailable() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationUnsupported,
        "TPM2 and IMA evidence is unavailable on this broker",
        false,
    )
}

const fn quote_collection_failed() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationFailed,
        "TPM2 quote collection failed on this broker",
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

    #[test]
    fn evidence_bundle_header_is_canonical_and_contiguous() -> Result<(), Box<dyn std::error::Error>>
    {
        let bundle = build_evidence_bundle([
            EvidenceRecord {
                kind: "ima_ascii_runtime_measurements",
                bytes: b"ima\n".to_vec(),
            },
            EvidenceRecord {
                kind: "uefi_binary_bios_measurements",
                bytes: b"uefi".to_vec(),
            },
            EvidenceRecord {
                kind: "installed_manifest",
                bytes: b"{\"schemaVersion\":1}\n".to_vec(),
            },
            EvidenceRecord {
                kind: "installed_manifest_signature",
                bytes: vec![7; 64],
            },
        ])?;
        assert_eq!(&bundle[..8], EVIDENCE_MAGIC);
        let header_len = u32::from_be_bytes(bundle[8..12].try_into()?) as usize;
        let header = std::str::from_utf8(&bundle[12..12 + header_len])?;
        assert!(header.starts_with(r#"{"records":["#));
        assert!(header.ends_with(r#"],"schemaVersion":1}"#));
        let parsed: serde_json::Value = serde_json::from_str(header)?;
        let records = parsed
            .get("records")
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| std::io::Error::other("missing records"))?;
        let mut cursor = EVIDENCE_PREFIX_BYTES + header_len;
        for record in records {
            assert_eq!(
                record.get("offset").and_then(serde_json::Value::as_u64),
                Some(cursor as u64)
            );
            let byte_length = record
                .get("byteLength")
                .and_then(serde_json::Value::as_u64)
                .ok_or_else(|| std::io::Error::other("missing byteLength"))?
                as usize;
            let digest = record
                .get("sha256")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| std::io::Error::other("missing sha256"))?;
            assert_eq!(digest, sha256_hex(&bundle[cursor..cursor + byte_length]));
            cursor += byte_length;
        }
        assert_eq!(cursor, bundle.len());
        Ok(())
    }

    #[cfg(target_os = "linux")]
    #[test]
    #[allow(
        unsafe_code,
        reason = "test-only root privilege check for private TPM state"
    )]
    fn attest_collects_tpm_quote_and_sealed_bundle() -> Result<(), Box<dyn std::error::Error>> {
        use crate::linux::validate_evidence_bundle_fd;
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        // Production enrollment state must be root-owned. Non-root CI cannot
        // construct that identity without privileges, so leave this integration
        // path to the root-capable Linux package lane.
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            return Ok(());
        }

        let root = temp_test_dir("attestd-tpm-quote")?;
        let enrollment_path = root.join(ENROLLMENT_STATE_FILE);
        let ak_context_path = root.join(AK_CONTEXT_FILE);
        let manifest_path = root.join("installed-manifest.json");
        let manifest_signature_path = root.join("installed-manifest.json.sig");
        let ima_path = root.join("ascii_runtime_measurements");
        let measured_boot_path = root.join("binary_bios_measurements");

        let ak_base64 = "YWstdHBtMmI=";
        let device_id = device_id_for_ak(b"ak-tpm2b");
        fs::write(&enrollment_path, enrollment_json(ak_base64, &device_id))?;
        fs::set_permissions(&enrollment_path, fs::Permissions::from_mode(0o600))?;
        fs::write(&ak_context_path, b"ak-context")?;
        fs::set_permissions(&ak_context_path, fs::Permissions::from_mode(0o600))?;
        fs::write(&manifest_path, b"{\"schemaVersion\":1}\n")?;
        fs::write(&manifest_signature_path, vec![9; 64])?;
        fs::write(
            &ima_path,
            b"10 hash ima-ng sha256:00 /usr/bin/openburnbar-daemon\n",
        )?;
        fs::write(&measured_boot_path, b"measured-boot")?;

        let mut peer = peer();
        peer.installed_release.release_digest_sha256 = sha256_hex(b"{\"schemaVersion\":1}\n");
        let binding = binding_for_enrollment(
            &peer,
            &EnrollmentState {
                device_id: device_id.clone(),
            },
        );
        let request = AttestRequest {
            request_id: "attest-1".to_owned(),
            challenge: crate::protocol::Challenge {
                challenge_id: "challenge-1".to_owned(),
                challenge: "bm9uY2UtMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODk".to_owned(),
                expires_at_millis: 1_900_000_120_000,
                app_id: binding.app_id.clone(),
                policy_id: binding.policy_id.clone(),
                protocol_version: 1,
            },
            binding,
        };
        let qualifying_data =
            qualifying_data_sha256(&request.challenge.challenge, &request.binding)?;
        let tpm2_quote_path = root.join("tpm2_quote");
        fs::write(
            &tpm2_quote_path,
            format!(
                r#"#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in
    -Q) shift ;;
    -q) q=$2; shift 2 ;;
    -m) message=$2; shift 2 ;;
    -s) signature=$2; shift 2 ;;
    -o) pcr=$2; shift 2 ;;
    *) shift 2 ;;
  esac
done
[ "${{q:-}}" = "{qualifying_data}" ] || exit 42
printf '%s' quote-attestation > "$message"
printf '%s' quote-signature > "$signature"
printf '%s' quote-pcr-values > "$pcr"
"#
            ),
        )?;
        fs::set_permissions(&tpm2_quote_path, fs::Permissions::from_mode(0o755))?;

        let backend = TpmImaAttestationBackend::with_paths(
            enrollment_path,
            ak_context_path,
            manifest_path,
            manifest_signature_path,
            ima_path,
            vec![measured_boot_path],
            tpm2_quote_path,
        )?;
        let result = backend.attest(&request, &peer)?;
        assert_eq!(result.attestation.evidence.device_id, device_id);
        assert_eq!(
            result.attestation.evidence.quote_attestation_base64,
            "cXVvdGUtYXR0ZXN0YXRpb24="
        );
        assert_eq!(
            result.attestation.evidence.quote_signature_base64,
            "cXVvdGUtc2lnbmF0dXJl"
        );
        assert_eq!(
            result.attestation.evidence.quote_pcr_values_base64,
            "cXVvdGUtcGNyLXZhbHVlcw=="
        );
        validate_evidence_bundle_fd(&result.evidence_bundle, &result.attestation.evidence_bundle)?;
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn temp_test_dir(prefix: &str) -> Result<PathBuf, std::io::Error> {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let path = std::env::temp_dir().join(format!(
            "{prefix}-{}-{}",
            std::process::id(),
            TEST_TEMP_DIR_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(path)
    }
}
