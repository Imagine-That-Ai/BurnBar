use std::collections::BTreeSet;
use std::env;
use std::fs::{File, Metadata, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use ed25519_dalek::pkcs8::DecodePublicKey;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::auth::{AuthorizedPeer, PeerAuthorizer, PeerCredentials};
use crate::error::{BrokerError, ErrorCode};
use crate::server::MAX_PACKET_BYTES;

const SYSTEMD_LISTEN_FD: i32 = 3;
const MAX_EXECUTABLE_BYTES: u64 = 512 * 1024 * 1024;
const MAX_MANIFEST_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct ProcPeerAuthorizer {
    daemon_path: PathBuf,
    manifest_path: PathBuf,
    manifest_signature_path: PathBuf,
    public_key_path: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InstalledFilesManifest {
    schema_version: u32,
    product: String,
    package_version: String,
    package_architecture: String,
    package_format: String,
    authorized_clients: Vec<InstalledFile>,
    app_id: String,
    git_commit: String,
    package_name: String,
    policy_id: String,
    broker_protocol_version: u32,
    installed_files_root_sha256: String,
    files: Vec<ReleaseFile>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InstalledFile {
    role: String,
    path: PathBuf,
    sha256: String,
    owner_uid: u32,
    owner_gid: u32,
    mode: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReleaseFile {
    path: PathBuf,
    r#type: String,
    sha256: Option<String>,
    size: Option<u64>,
    mode: String,
    uid: u32,
    gid: u32,
    target: Option<String>,
}

#[derive(Clone, Copy, Debug)]
struct FileIdentity {
    is_regular: bool,
    uid: u32,
    gid: u32,
    mode: u32,
    links: u64,
    size: u64,
    device: u64,
    inode: u64,
}

impl From<&Metadata> for FileIdentity {
    fn from(metadata: &Metadata) -> Self {
        Self {
            is_regular: metadata.file_type().is_file(),
            uid: metadata.uid(),
            gid: metadata.gid(),
            mode: metadata.mode() & 0o7777,
            links: metadata.nlink(),
            size: metadata.len(),
            device: metadata.dev(),
            inode: metadata.ino(),
        }
    }
}

impl ProcPeerAuthorizer {
    pub fn new(
        daemon_path: PathBuf,
        manifest_path: PathBuf,
        manifest_signature_path: PathBuf,
        public_key_path: PathBuf,
    ) -> Result<Self, BrokerError> {
        if !daemon_path.is_absolute()
            || !manifest_path.is_absolute()
            || !manifest_signature_path.is_absolute()
            || !public_key_path.is_absolute()
        {
            return Err(internal("authorization paths must be absolute"));
        }
        Ok(Self {
            daemon_path,
            manifest_path,
            manifest_signature_path,
            public_key_path,
        })
    }

    fn authorize_inner(&self, peer: PeerCredentials) -> Result<String, BrokerError> {
        if peer.pid == 0 {
            return Err(unauthorized("peer PID is invalid"));
        }
        // Signature verification precedes every use of manifest-controlled data.
        // Reloading on each request also makes package upgrades atomic to the broker.
        let manifest = load_signed_manifest(
            &self.manifest_path,
            &self.manifest_signature_path,
            &self.public_key_path,
        )?;
        validate_manifest(&manifest)?;
        let mut entries = manifest
            .authorized_clients
            .iter()
            .filter(|entry| entry.path == self.daemon_path);
        let entry = entries
            .next()
            .ok_or_else(|| unauthorized("daemon is absent from signed installed manifest"))?;
        if entries.next().is_some() {
            return Err(unauthorized(
                "signed installed manifest contains duplicate daemon entries",
            ));
        }
        validate_manifest_entry(entry)?;
        validate_authorized_entry_inventory(entry, &manifest.files)?;

        // Opening /proc/<pid>/exe pins the inode before resolving its path. The
        // separately O_NOFOLLOW-opened installed path must resolve to that same inode.
        let proc_exe_path = PathBuf::from(format!("/proc/{}/exe", peer.pid));
        let mut peer_executable = File::open(&proc_exe_path)
            .map_err(|_| unauthorized("peer executable cannot be opened"))?;
        let peer_fd_path = PathBuf::from(format!("/proc/self/fd/{}", peer_executable.as_raw_fd()));
        let resolved_path = std::fs::read_link(peer_fd_path)
            .map_err(|_| unauthorized("peer executable path cannot be resolved"))?;
        validate_resolved_path(&resolved_path, &self.daemon_path)?;

        let installed_executable = open_no_follow(&self.daemon_path)
            .map_err(|_| unauthorized("installed daemon cannot be opened securely"))?;
        let peer_metadata = peer_executable
            .metadata()
            .map_err(|_| unauthorized("peer executable metadata is unavailable"))?;
        let installed_metadata = installed_executable
            .metadata()
            .map_err(|_| unauthorized("installed daemon metadata is unavailable"))?;
        let peer_identity = FileIdentity::from(&peer_metadata);
        let installed_identity = FileIdentity::from(&installed_metadata);
        validate_executable_identity(peer_identity, entry)?;
        validate_executable_identity(installed_identity, entry)?;
        if peer_identity.device != installed_identity.device
            || peer_identity.inode != installed_identity.inode
        {
            return Err(unauthorized(
                "peer executable is not the installed daemon inode",
            ));
        }

        let digest = hash_open_file(&mut peer_executable, peer_identity.size)?;
        if digest != entry.sha256 {
            return Err(unauthorized("peer executable hash is not authorized"));
        }
        Ok(digest)
    }
}

impl PeerAuthorizer for ProcPeerAuthorizer {
    fn authorize(&self, peer: PeerCredentials) -> Result<AuthorizedPeer, BrokerError> {
        self.authorize_inner(peer)
            .map(|executable_sha256| AuthorizedPeer {
                credentials: peer,
                executable_sha256,
            })
    }
}

#[derive(Debug)]
pub struct SeqpacketListener {
    fd: OwnedFd,
}

#[derive(Debug)]
pub struct SeqpacketConnection {
    fd: OwnedFd,
}

#[derive(Debug)]
pub struct ReceivedPacket {
    pub bytes: Vec<u8>,
    pub credentials: PeerCredentials,
}

pub fn systemd_listener(socket_fd: i32) -> Result<SeqpacketListener, BrokerError> {
    let listen_pid = env::var("LISTEN_PID")
        .ok()
        .and_then(|value| value.parse::<u32>().ok());
    let listen_fds = env::var("LISTEN_FDS")
        .ok()
        .and_then(|value| value.parse::<u32>().ok());
    if socket_fd != SYSTEMD_LISTEN_FD
        || listen_pid != Some(std::process::id())
        || listen_fds != Some(1)
    {
        return Err(internal(
            "exactly one systemd socket-activation descriptor is required",
        ));
    }

    validate_socket_type(socket_fd)?;
    set_pass_credentials(socket_fd)?;
    // SAFETY: systemd's socket activation ABI transfers ownership of descriptor 3
    // to this process when LISTEN_PID matches and LISTEN_FDS is exactly one. The
    // descriptor is converted once and OwnedFd becomes its sole owner.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "systemd socket activation requires adopting inherited fd 3"
    )]
    let fd = unsafe { OwnedFd::from_raw_fd(SYSTEMD_LISTEN_FD) };
    Ok(SeqpacketListener { fd })
}

impl SeqpacketListener {
    pub fn accept(&self) -> Result<SeqpacketConnection, BrokerError> {
        let accepted = loop {
            // SAFETY: self.fd is a valid listening AF_UNIX SOCK_SEQPACKET descriptor;
            // null address pointers request no peer pathname, and accept4 returns a new fd.
            // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
            #[allow(
                unsafe_code,
                reason = "accepting a systemd-owned SOCK_SEQPACKET listener requires accept4"
            )]
            let result = unsafe {
                libc::accept4(
                    self.fd.as_raw_fd(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    libc::SOCK_CLOEXEC,
                )
            };
            if result >= 0 {
                break result;
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(BrokerError::io(
                    ErrorCode::Internal,
                    "cannot accept attestation connection",
                    error,
                ));
            }
        };
        // SAFETY: accept4 returned a new owned descriptor and this is its only
        // conversion to OwnedFd, ensuring every later error closes it automatically.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(unsafe_code, reason = "accept4 returns an owned file descriptor")]
        let fd = unsafe { OwnedFd::from_raw_fd(accepted) };
        set_pass_credentials(fd.as_raw_fd())?;
        Ok(SeqpacketConnection { fd })
    }
}

impl SeqpacketConnection {
    pub fn set_deadlines(&self, deadline: Duration) -> Result<(), BrokerError> {
        set_socket_timeout(self.fd.as_raw_fd(), libc::SO_RCVTIMEO, deadline)?;
        set_socket_timeout(self.fd.as_raw_fd(), libc::SO_SNDTIMEO, deadline)
    }

    pub fn receive_request(&self) -> Result<ReceivedPacket, BrokerError> {
        let mut bytes = vec![0_u8; MAX_PACKET_BYTES];
        let mut control = [0_usize; 16];
        let mut iov = libc::iovec {
            iov_base: bytes.as_mut_ptr().cast(),
            iov_len: bytes.len(),
        };
        // SAFETY: zero is a valid initial state for msghdr; all pointer-bearing
        // fields used by recvmsg are populated immediately below with live buffers.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(
            unsafe_code,
            reason = "recvmsg requires a zero-initialized platform msghdr"
        )]
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = std::ptr::addr_of_mut!(iov);
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = std::mem::size_of_val(&control);
        // SAFETY: message references writable buffers valid for the duration of the
        // call, and self owns a connected SOCK_SEQPACKET descriptor.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(
            unsafe_code,
            reason = "SCM_CREDENTIALS is available only through recvmsg ancillary data"
        )]
        let received = unsafe {
            libc::recvmsg(
                self.fd.as_raw_fd(),
                std::ptr::addr_of_mut!(message),
                libc::MSG_CMSG_CLOEXEC,
            )
        };
        if received < 0 {
            return Err(BrokerError::io(
                ErrorCode::InvalidFrame,
                "cannot receive broker request packet",
                std::io::Error::last_os_error(),
            ));
        }
        if message.msg_flags & libc::MSG_TRUNC != 0 {
            return Err(BrokerError::new(
                ErrorCode::RequestTooLarge,
                "broker request exceeds 64 KiB",
                false,
            ));
        }
        if message.msg_flags & libc::MSG_CTRUNC != 0 {
            return Err(unauthorized("request packet credentials were truncated"));
        }
        let credentials = packet_credentials(&message)?;
        let length = usize::try_from(received).map_err(|_| invalid_packet())?;
        bytes.truncate(length);
        Ok(ReceivedPacket { bytes, credentials })
    }

    pub fn send_response(&self, packet: &[u8]) -> Result<(), BrokerError> {
        if packet.len() > MAX_PACKET_BYTES {
            return Err(BrokerError::new(
                ErrorCode::ResponseTooLarge,
                "broker response exceeds 64 KiB",
                false,
            ));
        }
        // SAFETY: packet is a live readable buffer and self owns a connected
        // SOCK_SEQPACKET descriptor. MSG_NOSIGNAL prevents a peer-close signal.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(
            unsafe_code,
            reason = "sending one atomic SOCK_SEQPACKET record requires send"
        )]
        let sent = unsafe {
            libc::send(
                self.fd.as_raw_fd(),
                packet.as_ptr().cast(),
                packet.len(),
                libc::MSG_NOSIGNAL,
            )
        };
        if sent < 0 || usize::try_from(sent).ok() != Some(packet.len()) {
            return Err(BrokerError::io(
                ErrorCode::InvalidFrame,
                "cannot send broker response packet",
                std::io::Error::last_os_error(),
            ));
        }
        Ok(())
    }
}

fn packet_credentials(message: &libc::msghdr) -> Result<PeerCredentials, BrokerError> {
    let mut found = None;
    // SAFETY: message was populated by a successful recvmsg call and its control
    // buffer remains live. CMSG_* traverses only headers within msg_controllen.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "parsing SCM_CREDENTIALS requires libc CMSG traversal"
    )]
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET
                && (*header).cmsg_type == libc::SCM_CREDENTIALS
                && (*header).cmsg_len
                    >= libc::CMSG_LEN(std::mem::size_of::<libc::ucred>() as u32) as usize
            {
                if found.is_some() {
                    return Err(unauthorized("request packet has duplicate credentials"));
                }
                let raw = std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<libc::ucred>());
                if raw.pid <= 0 {
                    return Err(unauthorized("request packet credentials are invalid"));
                }
                found = Some(PeerCredentials {
                    pid: u32::try_from(raw.pid)
                        .map_err(|_| unauthorized("request packet PID is invalid"))?,
                    uid: raw.uid,
                    gid: raw.gid,
                });
            }
            header = libc::CMSG_NXTHDR(message, header);
        }
    }
    found.ok_or_else(|| unauthorized("request packet credentials are missing"))
}

fn validate_socket_type(fd: i32) -> Result<(), BrokerError> {
    let mut socket_type = 0_i32;
    let mut length = std::mem::size_of::<i32>() as libc::socklen_t;
    // SAFETY: socket_type and length point to initialized writable storage and fd
    // is the inherited descriptor being validated before ownership conversion.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "validating SOCK_SEQPACKET requires getsockopt SO_TYPE"
    )]
    let result = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_TYPE,
            std::ptr::addr_of_mut!(socket_type).cast(),
            std::ptr::addr_of_mut!(length),
        )
    };
    if result != 0 || socket_type != libc::SOCK_SEQPACKET {
        return Err(internal(
            "systemd descriptor must be an AF_UNIX SOCK_SEQPACKET listener",
        ));
    }
    let mut accepting = 0_i32;
    length = std::mem::size_of::<i32>() as libc::socklen_t;
    // SAFETY: accepting and length are initialized writable storage, and fd is
    // still the validated inherited socket descriptor.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "validating the inherited listener requires getsockopt SO_ACCEPTCONN"
    )]
    let accept_result = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_ACCEPTCONN,
            std::ptr::addr_of_mut!(accepting).cast(),
            std::ptr::addr_of_mut!(length),
        )
    };
    // SAFETY: zero is a valid initial sockaddr_storage representation and
    // getsockname populates at most the supplied storage length.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "validating AF_UNIX requires getsockname on the inherited descriptor"
    )]
    let mut address: libc::sockaddr_storage = unsafe { std::mem::zeroed() };
    let mut address_length = std::mem::size_of::<libc::sockaddr_storage>() as libc::socklen_t;
    // SAFETY: address and address_length point to initialized writable storage
    // sized for every socket address family.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "validating AF_UNIX requires getsockname on the inherited descriptor"
    )]
    let name_result = unsafe {
        libc::getsockname(
            fd,
            std::ptr::addr_of_mut!(address).cast(),
            std::ptr::addr_of_mut!(address_length),
        )
    };
    if accept_result != 0
        || accepting != 1
        || name_result != 0
        || i32::from(address.ss_family) != libc::AF_UNIX
    {
        return Err(internal(
            "systemd descriptor must be a listening AF_UNIX SOCK_SEQPACKET socket",
        ));
    }
    Ok(())
}

fn set_pass_credentials(fd: i32) -> Result<(), BrokerError> {
    let enabled = 1_i32;
    // SAFETY: enabled points to an initialized i32 of the supplied length and fd
    // is a live Unix socket owned by this process or awaiting ownership conversion.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "enabling per-packet SCM_CREDENTIALS requires setsockopt SO_PASSCRED"
    )]
    let result = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PASSCRED,
            std::ptr::addr_of!(enabled).cast(),
            std::mem::size_of::<i32>() as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(BrokerError::io(
            ErrorCode::Internal,
            "cannot enable per-packet peer credentials",
            std::io::Error::last_os_error(),
        ));
    }
    Ok(())
}

fn set_socket_timeout(fd: i32, option: i32, deadline: Duration) -> Result<(), BrokerError> {
    let timeout = libc::timeval {
        tv_sec: deadline
            .as_secs()
            .try_into()
            .map_err(|_| internal("socket deadline is invalid"))?,
        tv_usec: i64::from(deadline.subsec_micros()),
    };
    // SAFETY: timeout points to an initialized timeval of the supplied length and
    // fd is a live connected Unix socket.
    // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
    #[allow(
        unsafe_code,
        reason = "setting bounded socket I/O deadlines requires setsockopt"
    )]
    let result = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            option,
            std::ptr::addr_of!(timeout).cast(),
            std::mem::size_of::<libc::timeval>() as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(BrokerError::io(
            ErrorCode::Internal,
            "cannot set broker socket deadline",
            std::io::Error::last_os_error(),
        ));
    }
    Ok(())
}

const fn invalid_packet() -> BrokerError {
    BrokerError::new(ErrorCode::InvalidFrame, "broker packet is invalid", false)
}

fn load_signed_manifest(
    manifest_path: &Path,
    signature_path: &Path,
    public_key_path: &Path,
) -> Result<InstalledFilesManifest, BrokerError> {
    let manifest_bytes = read_root_owned_bounded_file(manifest_path, 0o644, MAX_MANIFEST_BYTES)?;
    let signature_bytes = read_root_owned_bounded_file(signature_path, 0o644, 64)?;
    let public_key_bytes = read_root_owned_bounded_file(public_key_path, 0o644, 4 * 1024)?;
    verify_manifest_signature(&manifest_bytes, &signature_bytes, &public_key_bytes)?;
    serde_json::from_slice(&manifest_bytes)
        .map_err(|_| manifest_signature_invalid("signed installed manifest is malformed"))
}

fn verify_manifest_signature(
    manifest: &[u8],
    signature: &[u8],
    public_key: &[u8],
) -> Result<(), BrokerError> {
    if signature.len() != 64 {
        return Err(manifest_signature_invalid(
            "detached manifest signature is invalid",
        ));
    }
    let public_key_pem = std::str::from_utf8(public_key)
        .map_err(|_| manifest_signature_invalid("release public key is invalid"))?;
    let verifying_key = VerifyingKey::from_public_key_pem(public_key_pem)
        .map_err(|_| manifest_signature_invalid("release public key is invalid"))?;
    let signature = Signature::from_slice(signature)
        .map_err(|_| manifest_signature_invalid("detached manifest signature is invalid"))?;
    verifying_key
        .verify_strict(manifest, &signature)
        .map_err(|_| manifest_signature_invalid("installed manifest signature verification failed"))
}

fn read_root_owned_bounded_file(
    path: &Path,
    expected_mode: u32,
    max_bytes: u64,
) -> Result<Vec<u8>, BrokerError> {
    let file = open_no_follow(path).map_err(|_| {
        manifest_signature_invalid("signed manifest input cannot be opened securely")
    })?;
    let metadata = file
        .metadata()
        .map_err(|_| manifest_signature_invalid("signed manifest input metadata is unavailable"))?;
    validate_root_owned_identity(FileIdentity::from(&metadata), expected_mode).map_err(|_| {
        manifest_signature_invalid("signed manifest input ownership or mode is unsafe")
    })?;
    if metadata.len() == 0 || metadata.len() > max_bytes {
        return Err(manifest_signature_invalid(
            "signed manifest input size is invalid",
        ));
    }
    let expected_size = usize::try_from(metadata.len())
        .map_err(|_| manifest_signature_invalid("signed manifest input size is invalid"))?;
    let mut bytes = Vec::with_capacity(expected_size);
    file.take(max_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| manifest_signature_invalid("signed manifest input cannot be read"))?;
    if bytes.len() != expected_size {
        return Err(manifest_signature_invalid(
            "signed manifest input changed while reading",
        ));
    }
    Ok(bytes)
}

fn open_no_follow(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
}

fn validate_manifest(manifest: &InstalledFilesManifest) -> Result<(), BrokerError> {
    if manifest.schema_version != 1
        || manifest.product != "OpenBurnBar"
        || !valid_package_version(&manifest.package_version)
        || !matches!(manifest.package_architecture.as_str(), "aarch64" | "x86_64")
        || !matches!(manifest.package_format.as_str(), "deb" | "rpm")
        || manifest.authorized_clients.is_empty()
        || manifest.authorized_clients.len() > 8
        || manifest.app_id != "dev.openburnbar.OpenBurnBar"
        || !valid_lower_hex(&manifest.git_commit, 40)
        || manifest.package_name != "open-burn-bar"
        || manifest.policy_id != "openburnbar-linux-tpm2-ima-v1"
        || manifest.broker_protocol_version != 1
        || !valid_lower_hex(&manifest.installed_files_root_sha256, 64)
        || manifest.files.is_empty()
        || manifest.files.len() > 4_096
    {
        return Err(manifest_signature_invalid(
            "signed installed manifest fields are invalid",
        ));
    }
    let mut paths = BTreeSet::new();
    for file in &manifest.files {
        let path = file.path.to_str().unwrap_or_default();
        let file_shape_valid = match file.r#type.as_str() {
            "file" => {
                file.sha256
                    .as_ref()
                    .is_some_and(|digest| valid_lower_hex(digest, 64))
                    && file.size.is_some_and(|size| size <= 2_147_483_648)
                    && file.target.is_none()
            }
            "symlink" => {
                file.sha256.is_none()
                    && file.size.is_none()
                    && file.target.as_ref().is_some_and(|target| {
                        !target.is_empty() && target.len() <= 4_096 && !target.contains('\0')
                    })
            }
            _ => false,
        };
        if !path.starts_with("/usr/")
            || path.len() > 4_096
            || path.contains('\0')
            || !paths.insert(path)
            || !file_shape_valid
            || file.mode.len() != 4
            || !file.mode.bytes().all(|byte| matches!(byte, b'0'..=b'7'))
            || file.uid != 0
            || file.gid != 0
        {
            return Err(manifest_signature_invalid(
                "signed installed manifest file inventory is invalid",
            ));
        }
    }
    let actual_root = installed_files_root(&manifest.files)?;
    if actual_root != manifest.installed_files_root_sha256 {
        return Err(manifest_signature_invalid(
            "signed installed manifest file inventory root does not match",
        ));
    }
    Ok(())
}

fn installed_files_root(files: &[ReleaseFile]) -> Result<String, BrokerError> {
    let mut records = Vec::with_capacity(files.len());
    for file in files {
        let path = file
            .path
            .to_str()
            .ok_or_else(|| manifest_signature_invalid("signed file inventory path is not UTF-8"))?;
        let record = match file.r#type.as_str() {
            "file" => format!(
                "{path}\0file\0{}\0{}\0{}\0{}\0{}",
                file.sha256.as_deref().unwrap_or_default(),
                file.size.unwrap_or_default(),
                file.mode,
                file.uid,
                file.gid
            ),
            "symlink" => format!(
                "{path}\0symlink\0{}\0{}\0{}\0{}",
                file.target.as_deref().unwrap_or_default(),
                file.mode,
                file.uid,
                file.gid
            ),
            _ => {
                return Err(manifest_signature_invalid(
                    "signed file inventory type is invalid",
                ));
            }
        };
        records.push(record);
    }
    records.sort_unstable_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
    let mut hasher = Sha256::new();
    hasher.update(records.join("\n").as_bytes());
    Ok(format!("{:x}", hasher.finalize()))
}

fn validate_authorized_entry_inventory(
    entry: &InstalledFile,
    files: &[ReleaseFile],
) -> Result<(), BrokerError> {
    let mut matching = files.iter().filter(|file| file.path == entry.path);
    let file = matching
        .next()
        .ok_or_else(|| unauthorized("authorized daemon is absent from signed file inventory"))?;
    if matching.next().is_some()
        || file.r#type != "file"
        || file.sha256.as_deref() != Some(entry.sha256.as_str())
        || file.mode != format!("{:04o}", entry.mode)
        || file.uid != entry.owner_uid
        || file.gid != entry.owner_gid
        || file
            .size
            .is_none_or(|size| size == 0 || size > MAX_EXECUTABLE_BYTES)
        || file.target.is_some()
    {
        return Err(unauthorized(
            "authorized daemon does not match signed file inventory",
        ));
    }
    Ok(())
}

fn valid_lower_hex(value: &str, expected_length: usize) -> bool {
    value.len() == expected_length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn validate_manifest_entry(entry: &InstalledFile) -> Result<(), BrokerError> {
    if entry.role != "daemon"
        || entry.owner_uid != 0
        || entry.owner_gid != 0
        || entry.mode != 0o755
        || entry.sha256.len() != 64
        || !entry
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(unauthorized("installed daemon manifest entry is invalid"));
    }
    Ok(())
}

fn validate_resolved_path(actual: &Path, expected: &Path) -> Result<(), BrokerError> {
    if actual != expected {
        return Err(unauthorized("peer executable path is not authorized"));
    }
    Ok(())
}

fn validate_root_owned_identity(
    identity: FileIdentity,
    expected_mode: u32,
) -> Result<(), BrokerError> {
    if !identity.is_regular
        || identity.uid != 0
        || identity.gid != 0
        || identity.mode != expected_mode
        || identity.links != 1
    {
        return Err(unauthorized("installed file ownership or mode is unsafe"));
    }
    Ok(())
}

fn validate_executable_identity(
    identity: FileIdentity,
    entry: &InstalledFile,
) -> Result<(), BrokerError> {
    validate_root_owned_identity(identity, entry.mode)?;
    if identity.size == 0 || identity.size > MAX_EXECUTABLE_BYTES {
        return Err(unauthorized("installed daemon size is invalid"));
    }
    Ok(())
}

fn hash_open_file(file: &mut File, size: u64) -> Result<String, BrokerError> {
    if size == 0 || size > MAX_EXECUTABLE_BYTES {
        return Err(unauthorized("peer executable size is invalid"));
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| unauthorized("peer executable cannot be hashed"))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut total = 0_u64;
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| unauthorized("peer executable cannot be hashed"))?;
        if read == 0 {
            break;
        }
        total = total.saturating_add(read as u64);
        if total > size || total > MAX_EXECUTABLE_BYTES {
            return Err(unauthorized("peer executable changed while hashing"));
        }
        hasher.update(&buffer[..read]);
    }
    if total != size {
        return Err(unauthorized("peer executable changed while hashing"));
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn valid_package_version(value: &str) -> bool {
    let mut parts = value.split('.');
    let valid_part = |part: &str| {
        !part.is_empty()
            && part.bytes().all(|byte| byte.is_ascii_digit())
            && (part == "0" || !part.starts_with('0'))
    };
    parts.by_ref().take(3).all(valid_part)
        && value.matches('.').count() == 2
        && parts.next().is_none()
}

const fn unauthorized(message: &'static str) -> BrokerError {
    BrokerError::new(ErrorCode::UnauthorizedPeer, message, false)
}

const fn manifest_signature_invalid(message: &'static str) -> BrokerError {
    BrokerError::new(ErrorCode::ManifestSignatureInvalid, message, false)
}

const fn internal(message: &'static str) -> BrokerError {
    BrokerError::new(ErrorCode::Internal, message, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::pkcs8::spki::der::pem::LineEnding;
    use ed25519_dalek::pkcs8::EncodePublicKey;
    use ed25519_dalek::{Signer, SigningKey};
    use std::os::unix::fs::symlink;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or_default();
        let path = env::temp_dir().join(format!(
            "openburnbar-attestd-{label}-{}-{nonce}",
            std::process::id()
        ));
        assert!(std::fs::create_dir(&path).is_ok());
        path
    }

    fn valid_entry() -> InstalledFile {
        InstalledFile {
            role: "daemon".to_owned(),
            path: PathBuf::from("/usr/bin/openburnbar-daemon"),
            sha256: "a".repeat(64),
            owner_uid: 0,
            owner_gid: 0,
            mode: 0o755,
        }
    }

    fn valid_release_file() -> ReleaseFile {
        ReleaseFile {
            path: PathBuf::from("/usr/bin/openburnbar-daemon"),
            r#type: "file".to_owned(),
            sha256: Some("a".repeat(64)),
            size: Some(100),
            mode: "0755".to_owned(),
            uid: 0,
            gid: 0,
            target: None,
        }
    }

    fn valid_manifest() -> InstalledFilesManifest {
        let files = vec![valid_release_file()];
        InstalledFilesManifest {
            schema_version: 1,
            product: "OpenBurnBar".to_owned(),
            package_version: "1.2.3".to_owned(),
            package_architecture: "x86_64".to_owned(),
            package_format: "deb".to_owned(),
            authorized_clients: vec![valid_entry()],
            app_id: "dev.openburnbar.OpenBurnBar".to_owned(),
            git_commit: "b".repeat(40),
            package_name: "open-burn-bar".to_owned(),
            policy_id: "openburnbar-linux-tpm2-ima-v1".to_owned(),
            broker_protocol_version: 1,
            installed_files_root_sha256: installed_files_root(&files).unwrap_or_default(),
            files,
        }
    }

    fn root_identity(mode: u32) -> FileIdentity {
        FileIdentity {
            is_regular: true,
            uid: 0,
            gid: 0,
            mode,
            links: 1,
            size: 100,
            device: 1,
            inode: 2,
        }
    }

    #[test]
    fn scm_credentials_identify_actual_writer_on_inherited_socket(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut descriptors = [-1_i32; 2];
        // SAFETY: descriptors points to storage for exactly two fds; AF_UNIX
        // SOCK_SEQPACKET socketpair initializes both on success.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(
            unsafe_code,
            reason = "the kernel credential regression requires a real SOCK_SEQPACKET pair"
        )]
        let pair_result = unsafe {
            libc::socketpair(
                libc::AF_UNIX,
                libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC,
                0,
                descriptors.as_mut_ptr(),
            )
        };
        if pair_result != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: socketpair returned two new owned fds and each is converted once.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(unsafe_code, reason = "socketpair returns two owned file descriptors")]
        let receiver_fd = unsafe { OwnedFd::from_raw_fd(descriptors[0]) };
        // SAFETY: same socketpair ownership invariant for the sender endpoint.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(unsafe_code, reason = "socketpair returns two owned file descriptors")]
        let sender_fd = unsafe { OwnedFd::from_raw_fd(descriptors[1]) };
        set_pass_credentials(receiver_fd.as_raw_fd())?;
        let receiver = SeqpacketConnection { fd: receiver_fd };
        let sender_raw = sender_fd.as_raw_fd();
        let request = [0_u8, 0, 0, 1, b'x'];

        // SAFETY: after fork the child performs only async-signal-safe send and
        // _exit calls. The inherited sender fd is deliberately shared so this test
        // proves SCM_CREDENTIALS follows the packet writer, not socket creator.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(
            unsafe_code,
            reason = "fork is required to prove credentials bind to the actual packet writer"
        )]
        let child = unsafe { libc::fork() };
        if child < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        if child == 0 {
            // SAFETY: request remains valid in the forked address space; sender_raw
            // names the inherited connected endpoint, and _exit runs unconditionally.
            // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
            #[allow(
                unsafe_code,
                reason = "child sends a static packet and exits without running Rust destructors"
            )]
            unsafe {
                let sent = libc::send(
                    sender_raw,
                    request.as_ptr().cast(),
                    request.len(),
                    libc::MSG_NOSIGNAL,
                );
                libc::_exit(i32::from(sent != request.len() as isize));
            }
        }
        drop(sender_fd);
        let received = receiver.receive_request()?;
        let mut status = 0_i32;
        // SAFETY: child is the positive PID returned by fork and status is writable.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(
            unsafe_code,
            reason = "the credential regression must reap its forked child deterministically"
        )]
        let waited = unsafe { libc::waitpid(child, std::ptr::addr_of_mut!(status), 0) };
        assert_eq!(waited, child);
        assert_eq!(status, 0);
        assert_eq!(received.bytes, request);
        assert_eq!(received.credentials.pid, u32::try_from(child)?);
        // SAFETY: getuid/getgid have no preconditions and return the current IDs.
        // reason: Unsafe libc boundary is justified by the adjacent SAFETY invariant.
        #[allow(
            unsafe_code,
            reason = "comparing SCM_CREDENTIALS to the current real IDs requires getuid/getgid"
        )]
        unsafe {
            assert_eq!(received.credentials.uid, libc::getuid());
            assert_eq!(received.credentials.gid, libc::getgid());
        }
        Ok(())
    }

    #[test]
    fn installed_files_root_matches_cross_language_golden_vector(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let files = vec![
            ReleaseFile {
                path: PathBuf::from("/usr/share/openburnbar/\u{00e9}.txt"),
                r#type: "file".to_owned(),
                sha256: Some("05".repeat(32)),
                size: Some(5),
                mode: "0644".to_owned(),
                uid: 0,
                gid: 0,
                target: None,
            },
            ReleaseFile {
                path: PathBuf::from("/usr/lib/openburnbar/current"),
                r#type: "symlink".to_owned(),
                sha256: None,
                size: None,
                mode: "0777".to_owned(),
                uid: 0,
                gid: 0,
                target: Some("../v1".to_owned()),
            },
            ReleaseFile {
                path: PathBuf::from(
                    "/usr/share/applications/dev.openburnbar.OpenBurnBar.SafeMode.desktop",
                ),
                r#type: "file".to_owned(),
                sha256: Some("04".repeat(32)),
                size: Some(4),
                mode: "0644".to_owned(),
                uid: 0,
                gid: 0,
                target: None,
            },
            ReleaseFile {
                path: PathBuf::from("/usr/bin/openburnbar-daemon"),
                r#type: "file".to_owned(),
                sha256: Some("01".repeat(32)),
                size: Some(3),
                mode: "0755".to_owned(),
                uid: 0,
                gid: 0,
                target: None,
            },
            ReleaseFile {
                path: PathBuf::from("/usr/lib/openburnbar/_Swift.so"),
                r#type: "file".to_owned(),
                sha256: Some("03".repeat(32)),
                size: Some(3),
                mode: "0644".to_owned(),
                uid: 0,
                gid: 0,
                target: None,
            },
            ReleaseFile {
                path: PathBuf::from("/usr/share/applications/dev.openburnbar.OpenBurnBar.desktop"),
                r#type: "file".to_owned(),
                sha256: Some("02".repeat(32)),
                size: Some(2),
                mode: "0644".to_owned(),
                uid: 0,
                gid: 0,
                target: None,
            },
        ];
        assert_eq!(
            installed_files_root(&files)?,
            "b86bd33740f7c26f3b4f959afcb9a5cb055f3c3b127ad6ee9f3f627c1c30f9e4"
        );
        Ok(())
    }

    #[test]
    fn accepts_valid_signature_and_rejects_tampering_or_wrong_length(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let signing_key = SigningKey::from_bytes(&[7_u8; 32]);
        let public_key = signing_key
            .verifying_key()
            .to_public_key_pem(LineEnding::LF)?;
        let manifest = br#"{"schemaVersion":1}"#;
        let signature = signing_key.sign(manifest).to_bytes();
        assert!(verify_manifest_signature(manifest, &signature, public_key.as_bytes()).is_ok());
        assert_eq!(
            verify_manifest_signature(b"tampered", &signature, public_key.as_bytes())
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::ManifestSignatureInvalid)
        );
        assert_eq!(
            verify_manifest_signature(manifest, &signature[..63], public_key.as_bytes())
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::ManifestSignatureInvalid)
        );
        Ok(())
    }

    #[test]
    fn rejects_manifest_symlink() {
        let root = temp_dir("manifest-symlink");
        let target = root.join("target.json");
        assert!(std::fs::write(&target, b"{}").is_ok());
        let link = root.join("manifest.json");
        assert!(symlink(&target, &link).is_ok());
        assert!(open_no_follow(&link).is_err());
        assert!(std::fs::remove_dir_all(root).is_ok());
    }

    #[test]
    fn validates_path_hash_owner_and_mode() {
        let valid = valid_entry();
        assert!(validate_manifest_entry(&valid).is_ok());
        assert!(validate_resolved_path(&valid.path, &valid.path).is_ok());
        assert!(validate_resolved_path(Path::new("/tmp/daemon"), &valid.path).is_err());

        let mut invalid_hash = valid_entry();
        invalid_hash.sha256 = "f".repeat(63);
        assert!(validate_manifest_entry(&invalid_hash).is_err());
        let mut uppercase_hash = valid_entry();
        uppercase_hash.sha256 = "A".repeat(64);
        assert!(validate_manifest_entry(&uppercase_hash).is_err());
        let mut invalid_owner = valid_entry();
        invalid_owner.owner_uid = 1;
        assert!(validate_manifest_entry(&invalid_owner).is_err());
        let mut invalid_mode = valid_entry();
        invalid_mode.mode = 0o775;
        assert!(validate_manifest_entry(&invalid_mode).is_err());

        assert!(validate_root_owned_identity(root_identity(0o755), 0o755).is_ok());
        let mut actual_owner = root_identity(0o755);
        actual_owner.uid = 1_000;
        assert!(validate_root_owned_identity(actual_owner, 0o755).is_err());
        assert!(validate_root_owned_identity(root_identity(0o775), 0o755).is_err());
        let mut hard_linked = root_identity(0o755);
        hard_linked.links = 2;
        assert!(validate_root_owned_identity(hard_linked, 0o755).is_err());
    }

    #[test]
    fn validates_exact_release_manifest_shape() {
        let valid = valid_manifest();
        assert!(validate_manifest(&valid).is_ok());
        assert!(
            validate_authorized_entry_inventory(&valid.authorized_clients[0], &valid.files).is_ok()
        );

        let mut invalid_version = valid_manifest();
        invalid_version.package_version = "01.2.3".to_owned();
        assert!(validate_manifest(&invalid_version).is_err());

        let mut duplicate = valid_manifest();
        duplicate.files.push(valid_release_file());
        assert!(validate_manifest(&duplicate).is_err());

        let mut outside_usr = valid_manifest();
        outside_usr.files[0].path = PathBuf::from("/etc/openburnbar-daemon");
        assert!(validate_manifest(&outside_usr).is_err());

        let mut mismatched_inventory = valid_manifest();
        mismatched_inventory.files[0].sha256 = Some("d".repeat(64));
        assert!(validate_authorized_entry_inventory(
            &mismatched_inventory.authorized_clients[0],
            &mismatched_inventory.files
        )
        .is_err());
    }

    #[test]
    fn hashes_the_pinned_open_file() {
        let root = temp_dir("hash");
        let path = root.join("file");
        assert!(std::fs::write(&path, b"abc").is_ok());
        let file = File::open(&path);
        assert!(file.is_ok());
        if let Ok(mut file) = file {
            assert_eq!(
                hash_open_file(&mut file, 3).ok().as_deref(),
                Some("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            );
            assert!(hash_open_file(&mut file, 4).is_err());
        }
        assert!(std::fs::remove_dir_all(root).is_ok());
    }
}
