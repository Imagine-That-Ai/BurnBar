use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64ct::{Base64, Encoding};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::config::InitializeAkConfig;
use crate::error::{BrokerError, ErrorCode};

const ENROLLMENT_STATE_FILE: &str = "tpm-enrollment.json";
const AK_CONTEXT_FILE: &str = "ak.ctx";
const MAX_AK_CONTEXT_BYTES: usize = 512 * 1024;
const MAX_AK_TPM_BYTES: usize = 64 * 1024;
const MAX_EK_TPM_BYTES: usize = 64 * 1024;
const MAX_EK_CERTIFICATE_BYTES: usize = 128 * 1024;
const TPM_CREATEAK_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AkLifecycleReceipt {
    pub schema_version: u32,
    pub device_id: String,
    pub agent_id: String,
    pub ak_tpm_sha256: String,
    pub ek_tpm_sha256: String,
    pub ek_certificate_sha256: String,
    pub enrollment_state_path: String,
    pub ak_context_path: String,
    pub rotated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EnrollmentStateDocument<'a> {
    schema_version: u32,
    device_id: &'a str,
    agent_id: &'a str,
    ak_tpm_base64: String,
    ek_tpm_base64: String,
    ek_certificate_base64: String,
    enrolled_at_millis: i64,
}

struct AkCreatePaths {
    work_dir: PathBuf,
    ak_context: PathBuf,
    ak_public: PathBuf,
    ak_name: PathBuf,
    ak_qualified_name: PathBuf,
}

pub fn initialize_tpm_ak(config: &InitializeAkConfig) -> Result<AkLifecycleReceipt, BrokerError> {
    let now_millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| lifecycle_failed())?
        .as_millis()
        .try_into()
        .map_err(|_| lifecycle_failed())?;
    initialize_tpm_ak_at(config, now_millis)
}

fn initialize_tpm_ak_at(
    config: &InitializeAkConfig,
    now_millis: i64,
) -> Result<AkLifecycleReceipt, BrokerError> {
    ensure_private_state_dir(&config.state_dir)?;
    let _state_lock = acquire_state_lock(&config.state_dir)?;
    let enrollment_state_path = config.state_dir.join(ENROLLMENT_STATE_FILE);
    let ak_context_path = config.state_dir.join(AK_CONTEXT_FILE);
    if !config.rotate
        && (path_exists_no_follow(&enrollment_state_path)?
            || path_exists_no_follow(&ak_context_path)?)
    {
        return Err(BrokerError::new(
            ErrorCode::InvalidRequest,
            "TPM2 AK lifecycle state already exists; use --rotate",
            false,
        ));
    }

    validate_private_input_file(&config.ek_context, MAX_AK_CONTEXT_BYTES)?;
    let ek_public = read_required_private_file(&config.ek_public, MAX_EK_TPM_BYTES)?;
    let ek_certificate =
        read_required_private_file(&config.ek_certificate, MAX_EK_CERTIFICATE_BYTES)?;
    let create_paths = AkCreatePaths::new(&config.state_dir)?;
    let result = (|| {
        run_tpm2_createak(config, &create_paths)?;
        normalize_generated_files(&create_paths)?;
        validate_private_input_file(&create_paths.ak_context, MAX_AK_CONTEXT_BYTES)?;
        let ak_public = read_required_private_file(&create_paths.ak_public, MAX_AK_TPM_BYTES)?;
        validate_private_input_file(&create_paths.ak_name, MAX_AK_TPM_BYTES)?;
        validate_private_input_file(&create_paths.ak_qualified_name, MAX_AK_TPM_BYTES)?;

        let ak_tpm_sha256 = sha256_hex(&ak_public);
        let ek_tpm_sha256 = sha256_hex(&ek_public);
        let ek_certificate_sha256 = sha256_hex(&ek_certificate);
        let device_id = format!("ak-sha256:{ak_tpm_sha256}");
        let enrollment = EnrollmentStateDocument {
            schema_version: 1,
            device_id: &device_id,
            agent_id: &config.agent_id,
            ak_tpm_base64: encode_base64(&ak_public)?,
            ek_tpm_base64: encode_base64(&ek_public)?,
            ek_certificate_base64: encode_base64(&ek_certificate)?,
            enrolled_at_millis: now_millis,
        };
        let mut enrollment_bytes =
            serde_json::to_vec(&enrollment).map_err(|_| lifecycle_failed())?;
        enrollment_bytes.push(b'\n');
        install_private_file(&create_paths.ak_context, &ak_context_path)?;
        write_private_file_atomic(&config.state_dir, &enrollment_state_path, &enrollment_bytes)?;
        Ok(AkLifecycleReceipt {
            schema_version: 1,
            device_id,
            agent_id: config.agent_id.clone(),
            ak_tpm_sha256,
            ek_tpm_sha256,
            ek_certificate_sha256,
            enrollment_state_path: enrollment_state_path.display().to_string(),
            ak_context_path: ak_context_path.display().to_string(),
            rotated: config.rotate,
        })
    })();
    let _cleanup = fs::remove_dir_all(&create_paths.work_dir);
    result
}

impl AkCreatePaths {
    fn new(state_dir: &Path) -> Result<Self, BrokerError> {
        let work_dir = state_dir.join(format!(
            ".openburnbar-ak-init-{}-{}",
            std::process::id(),
            monotonic_suffix()
        ));
        fs::create_dir(&work_dir).map_err(|_| lifecycle_failed())?;
        fs::set_permissions(&work_dir, fs::Permissions::from_mode(0o700))
            .map_err(|_| lifecycle_failed())?;
        Ok(Self {
            ak_context: work_dir.join("ak.ctx"),
            ak_public: work_dir.join("ak.pub"),
            ak_name: work_dir.join("ak.name"),
            ak_qualified_name: work_dir.join("ak.qname"),
            work_dir,
        })
    }
}

fn monotonic_suffix() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0)
}

fn run_tpm2_createak(
    config: &InitializeAkConfig,
    paths: &AkCreatePaths,
) -> Result<(), BrokerError> {
    let mut child = Command::new(&config.tpm2_createak)
        .arg("-Q")
        .arg("-C")
        .arg(&config.ek_context)
        .arg("-c")
        .arg(&paths.ak_context)
        .arg("-G")
        .arg("ecc")
        .arg("-g")
        .arg("sha256")
        .arg("-s")
        .arg("ecdsa")
        .arg("-u")
        .arg(&paths.ak_public)
        .arg("-n")
        .arg(&paths.ak_name)
        .arg("-q")
        .arg(&paths.ak_qualified_name)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| lifecycle_failed())?;
    let deadline = Instant::now() + TPM_CREATEAK_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(_status)) => return Err(lifecycle_failed()),
            Ok(None) if Instant::now() >= deadline => {
                let _kill_result = child.kill();
                let _wait_result = child.wait();
                return Err(lifecycle_failed());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => return Err(lifecycle_failed()),
        }
    }
}

fn normalize_generated_files(paths: &AkCreatePaths) -> Result<(), BrokerError> {
    for path in [
        &paths.ak_context,
        &paths.ak_public,
        &paths.ak_name,
        &paths.ak_qualified_name,
    ] {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|_| lifecycle_failed())?;
    }
    Ok(())
}

fn ensure_private_state_dir(path: &Path) -> Result<(), BrokerError> {
    if !path.is_absolute() {
        return Err(lifecycle_failed());
    }
    let created = !path_exists_no_follow(path)?;
    if created {
        fs::create_dir_all(path).map_err(|_| lifecycle_failed())?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|_| lifecycle_failed())?;
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| lifecycle_failed())?;
    if !metadata.file_type().is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || metadata.mode() & 0o7777 != 0o700
    {
        return Err(lifecycle_failed());
    }
    Ok(())
}

#[expect(
    unsafe_code,
    reason = "POSIX flock has no safe std wrapper and is required for cross-process AK serialization"
)]
fn acquire_state_lock(state_dir: &Path) -> Result<File, BrokerError> {
    let path = state_dir.join(".initialize-ak.lock");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| lifecycle_failed())?;
    let metadata = file.metadata().map_err(|_| lifecycle_failed())?;
    if !metadata.file_type().is_file()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || metadata.mode() & 0o7777 != 0o600
        || metadata.nlink() != 1
    {
        return Err(lifecycle_failed());
    }
    // SAFETY: flock accepts any valid open descriptor. `file` remains alive for
    // the entire initialization transaction and releases the lock on drop.
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result != 0 {
        return Err(BrokerError::new(
            ErrorCode::InvalidRequest,
            "TPM2 AK lifecycle initialization is already running",
            true,
        ));
    }
    Ok(file)
}

fn path_exists_no_follow(path: &Path) -> Result<bool, BrokerError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(lifecycle_failed()),
    }
}

fn read_required_private_file(path: &Path, max_bytes: usize) -> Result<Vec<u8>, BrokerError> {
    validate_private_input_file(path, max_bytes)?;
    let file = open_no_follow(path).map_err(|_| lifecycle_failed())?;
    let mut bytes = Vec::new();
    file.take(max_bytes.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| lifecycle_failed())?;
    if bytes.is_empty() || bytes.len() > max_bytes {
        return Err(lifecycle_failed());
    }
    Ok(bytes)
}

fn validate_private_input_file(path: &Path, max_bytes: usize) -> Result<(), BrokerError> {
    let file = open_no_follow(path).map_err(|_| lifecycle_failed())?;
    let metadata = file.metadata().map_err(|_| lifecycle_failed())?;
    let mode = metadata.mode() & 0o7777;
    if !metadata.file_type().is_file()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || !matches!(mode, 0o400 | 0o600)
        || metadata.nlink() != 1
        || metadata.len() == 0
        || metadata.len() > max_bytes as u64
    {
        return Err(lifecycle_failed());
    }
    Ok(())
}

fn open_no_follow(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
}

fn install_private_file(source: &Path, destination: &Path) -> Result<(), BrokerError> {
    fs::set_permissions(source, fs::Permissions::from_mode(0o600))
        .map_err(|_| lifecycle_failed())?;
    validate_private_input_file(source, MAX_AK_CONTEXT_BYTES)?;
    fs::rename(source, destination).map_err(|_| lifecycle_failed())?;
    validate_private_input_file(destination, MAX_AK_CONTEXT_BYTES)
}

fn write_private_file_atomic(
    state_dir: &Path,
    destination: &Path,
    bytes: &[u8],
) -> Result<(), BrokerError> {
    if bytes.is_empty() || bytes.len() > MAX_AK_CONTEXT_BYTES {
        return Err(lifecycle_failed());
    }
    let temporary = state_dir.join(format!(
        ".{}.{}",
        destination
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("openburnbar-state"),
        monotonic_suffix()
    ));
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&temporary)
            .map_err(|_| lifecycle_failed())?;
        file.write_all(bytes).map_err(|_| lifecycle_failed())?;
        file.sync_all().map_err(|_| lifecycle_failed())?;
    }
    validate_private_input_file(&temporary, MAX_AK_CONTEXT_BYTES)?;
    fs::rename(&temporary, destination).map_err(|_| lifecycle_failed())?;
    validate_private_input_file(destination, MAX_AK_CONTEXT_BYTES)
}

fn encode_base64(bytes: &[u8]) -> Result<String, BrokerError> {
    if bytes.is_empty() {
        return Err(lifecycle_failed());
    }
    let mut encoded = vec![0_u8; bytes.len().saturating_add(2) / 3 * 4 + 4];
    let value = Base64::encode(bytes, &mut encoded).map_err(|_| lifecycle_failed())?;
    Ok(value.to_owned())
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

const fn lifecycle_failed() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationUnsupported,
        "TPM2 AK lifecycle initialization failed on this broker",
        false,
    )
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn temp_test_dir(prefix: &str) -> Result<PathBuf, std::io::Error> {
        let path = std::env::temp_dir().join(format!(
            "{prefix}-{}-{}",
            std::process::id(),
            monotonic_suffix()
        ));
        fs::create_dir(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(path)
    }

    fn write_private(path: &Path, bytes: &[u8]) -> Result<(), std::io::Error> {
        fs::write(path, bytes)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
    }

    #[test]
    fn initialize_ak_creates_private_context_and_enrollment_state(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let root = temp_test_dir("attestd-ak-lifecycle")?;
        let ek_context = root.join("ek.ctx");
        let ek_public = root.join("ek.pub");
        let ek_certificate = root.join("ek.cert");
        let fake_createak = root.join("tpm2_createak");
        write_private(&ek_context, b"ek-context")?;
        write_private(&ek_public, b"ek-public")?;
        write_private(&ek_certificate, b"ek-certificate")?;
        fs::write(
            &fake_createak,
            r#"#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in
    -Q) shift ;;
    -c) context=$2; shift 2 ;;
    -u) public=$2; shift 2 ;;
    -n) name=$2; shift 2 ;;
    -q) qname=$2; shift 2 ;;
    *) shift 2 ;;
  esac
done
printf '%s' ak-context > "$context"
printf '%s' ak-public > "$public"
printf '%s' ak-name > "$name"
printf '%s' ak-qualified-name > "$qname"
"#,
        )?;
        fs::set_permissions(&fake_createak, fs::Permissions::from_mode(0o755))?;
        let config = InitializeAkConfig {
            state_dir: root.clone(),
            ek_context,
            ek_public,
            ek_certificate,
            agent_id: "01234567-89ab-cdef-0123-456789abcdef".to_owned(),
            tpm2_createak: fake_createak,
            rotate: false,
        };
        let receipt = initialize_tpm_ak_at(&config, 1_900_000_000_000)?;
        assert_eq!(
            receipt.device_id,
            format!("ak-sha256:{}", sha256_hex(b"ak-public"))
        );
        let ak_context_path = root.join(AK_CONTEXT_FILE);
        let enrollment_path = root.join(ENROLLMENT_STATE_FILE);
        assert_eq!(fs::read(&ak_context_path)?, b"ak-context");
        assert_eq!(
            fs::metadata(&ak_context_path)?.permissions().mode() & 0o777,
            0o600
        );
        let enrollment: serde_json::Value = serde_json::from_slice(&fs::read(&enrollment_path)?)?;
        assert_eq!(enrollment["schemaVersion"], 1);
        assert_eq!(enrollment["deviceId"], receipt.device_id);
        assert_eq!(enrollment["akTpmBase64"], "YWstcHVibGlj");
        assert_eq!(enrollment["ekTpmBase64"], "ZWstcHVibGlj");
        assert_eq!(enrollment["ekCertificateBase64"], "ZWstY2VydGlmaWNhdGU=");
        assert_eq!(enrollment["enrolledAtMillis"], 1_900_000_000_000_i64);
        assert!(initialize_tpm_ak_at(&config, 1_900_000_000_001).is_err());

        let rotated = InitializeAkConfig {
            rotate: true,
            ..config
        };
        assert!(initialize_tpm_ak_at(&rotated, 1_900_000_000_002).is_ok());
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn existing_state_directory_is_rejected_without_chmod_side_effect(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let root = temp_test_dir("attestd-ak-state-mode")?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o755))?;
        assert!(ensure_private_state_dir(&root).is_err());
        assert_eq!(fs::metadata(&root)?.permissions().mode() & 0o777, 0o755);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn state_lock_rejects_concurrent_initialization() -> Result<(), Box<dyn std::error::Error>> {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            return Ok(());
        }
        let root = temp_test_dir("attestd-ak-state-lock")?;
        let first = acquire_state_lock(&root)?;
        let second = acquire_state_lock(&root);
        assert!(second.is_err());
        drop(first);
        assert!(acquire_state_lock(&root).is_ok());
        fs::remove_dir_all(root)?;
        Ok(())
    }
}
