use std::collections::BTreeSet;
use std::env;
use std::ffi::CString;
use std::fs::{File, Metadata, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use ed25519_dalek::pkcs8::DecodePublicKey;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::auth::{AuthorizedPeer, InstalledReleaseIdentity, PeerAuthorizer, PeerCredentials};
use crate::error::{BrokerError, ErrorCode};
use crate::protocol::{EvidenceBundle, ATTESTATION_KIND, MAX_EVIDENCE_BUNDLE_BYTES};
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
    firebase_app_id: String,
    git_commit: String,
    package_name: String,
    policy_id: String,
    broker_protocol_version: u32,
    installed_files_root_sha256: String,
    files: Vec<ReleaseFile>,
}

#[derive(Debug)]
struct LoadedInstalledManifest {
    manifest: InstalledFilesManifest,
    release_digest_sha256: String,
}

#[derive(Debug)]
struct AuthorizedInstallation {
    executable_sha256: String,
    installed_release: InstalledReleaseIdentity,
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

    fn authorize_inner(
        &self,
        peer: PeerCredentials,
    ) -> Result<AuthorizedInstallation, BrokerError> {
        if peer.pid == 0 {
            return Err(unauthorized("peer PID is invalid"));
        }
        // Signature verification precedes every use of manifest-controlled data.
        // Reloading on each request also makes package upgrades atomic to the broker.
        let loaded = load_signed_manifest(
            &self.manifest_path,
            &self.manifest_signature_path,
            &self.public_key_path,
        )?;
        let manifest = &loaded.manifest;
        validate_manifest(manifest)?;
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
        Ok(AuthorizedInstallation {
            executable_sha256: digest,
            installed_release: InstalledReleaseIdentity {
                firebase_app_id: manifest.firebase_app_id.clone(),
                app_version: manifest.package_version.clone(),
                architecture: manifest.package_architecture.clone(),
                release_digest_sha256: loaded.release_digest_sha256,
                policy_id: manifest.policy_id.clone(),
                attestation_kind: ATTESTATION_KIND.to_owned(),
            },
        })
    }
}

impl PeerAuthorizer for ProcPeerAuthorizer {
    fn authorize(&self, peer: PeerCredentials) -> Result<AuthorizedPeer, BrokerError> {
        self.authorize_inner(peer)
            .map(|installation| AuthorizedPeer {
                credentials: peer,
                executable_sha256: installation.executable_sha256,
                installed_release: installation.installed_release,
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

#[derive(Debug, Default)]
struct RequestAncillary {
    credentials: Vec<PeerCredentials>,
    rights: Vec<OwnedFd>,
    invalid: bool,
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
        let ancillary = collect_request_ancillary(&message);
        if message.msg_flags & libc::MSG_TRUNC != 0 {
            return Err(BrokerError::new(
                ErrorCode::RequestTooLarge,
                "broker request exceeds 64 KiB",
                false,
            ));
        }
        if message.msg_flags & libc::MSG_CTRUNC != 0 {
            return Err(unauthorized("request packet ancillary data was truncated"));
        }
        let credentials = ancillary.into_credentials()?;
        let length = usize::try_from(received).map_err(|_| invalid_packet())?;
        bytes.truncate(length);
        Ok(ReceivedPacket { bytes, credentials })
    }

    pub fn send_response(
        &self,
        packet: &[u8],
        evidence_bundle: Option<&OwnedFd>,
    ) -> Result<(), BrokerError> {
        let descriptors = evidence_bundle.map_or(&[][..], |fd| std::slice::from_ref(fd));
        let raw_descriptors: Vec<RawFd> = descriptors.iter().map(AsRawFd::as_raw_fd).collect();
        self.send_response_fds(packet, &raw_descriptors)
    }

    fn send_response_fds(&self, packet: &[u8], descriptors: &[RawFd]) -> Result<(), BrokerError> {
        if packet.len() > MAX_PACKET_BYTES {
            return Err(BrokerError::new(
                ErrorCode::ResponseTooLarge,
                "broker response exceeds 64 KiB",
                false,
            ));
        }
        if descriptors.len() > 1 {
            return Err(BrokerError::new(
                ErrorCode::AttestationFailed,
                "broker response carries an invalid evidence descriptor count",
                false,
            ));
        }
        let mut iov = libc::iovec {
            iov_base: packet.as_ptr().cast_mut().cast(),
            iov_len: packet.len(),
        };
        let mut control = [0_usize; 8];
        // SAFETY: zero is a valid initial state for msghdr; live buffers are
        // assigned before sendmsg observes any pointer-bearing fields.
        // reason: zero initialization is the valid starting state for the platform msghdr.
        #[allow(
            unsafe_code,
            reason = "sendmsg requires a zero-initialized platform msghdr"
        )]
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = std::ptr::addr_of_mut!(iov);
        message.msg_iovlen = 1;
        if let Some(descriptor) = descriptors.first() {
            message.msg_control = control.as_mut_ptr().cast();
            message.msg_controllen = std::mem::size_of_val(&control);
            // SAFETY: control is aligned usize storage and large enough for one
            // SCM_RIGHTS int. CMSG_FIRSTHDR/CMSG_DATA remain within that buffer.
            // reason: libc CMSG accessors are required to construct the single SCM_RIGHTS header.
            #[allow(
                unsafe_code,
                reason = "SCM_RIGHTS headers are constructed through libc CMSG accessors"
            )]
            unsafe {
                let header = libc::CMSG_FIRSTHDR(std::ptr::addr_of!(message));
                if header.is_null() {
                    return Err(internal("cannot construct evidence descriptor message"));
                }
                (*header).cmsg_level = libc::SOL_SOCKET;
                (*header).cmsg_type = libc::SCM_RIGHTS;
                (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as usize;
                std::ptr::write(libc::CMSG_DATA(header).cast::<RawFd>(), *descriptor);
                message.msg_controllen =
                    libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) as usize;
            }
        }
        // SAFETY: message points to live packet and optional control storage;
        // self owns the connected SOCK_SEQPACKET fd. One sendmsg is one record.
        // reason: sendmsg keeps response bytes and the evidence descriptor in one record.
        #[allow(
            unsafe_code,
            reason = "response bytes and SCM_RIGHTS must be sent as one atomic record"
        )]
        let sent = unsafe { libc::sendmsg(self.fd.as_raw_fd(), &message, libc::MSG_NOSIGNAL) };
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

pub fn validate_evidence_bundle_fd(
    fd: &OwnedFd,
    bundle: &EvidenceBundle,
) -> Result<(), BrokerError> {
    if bundle.byte_length == 0 || bundle.byte_length > MAX_EVIDENCE_BUNDLE_BYTES {
        return Err(invalid_evidence_fd());
    }
    // SAFETY: F_GETFD and F_GET_SEALS inspect the live descriptor without
    // changing ownership or dereferencing application memory.
    // reason: fcntl inspects descriptor flags, seals, and offset without changing ownership.
    #[allow(
        unsafe_code,
        reason = "descriptor flags and memfd seals are available only through fcntl"
    )]
    let (descriptor_flags, seals, offset) = unsafe {
        (
            libc::fcntl(fd.as_raw_fd(), libc::F_GETFD),
            libc::fcntl(fd.as_raw_fd(), libc::F_GET_SEALS),
            libc::lseek(fd.as_raw_fd(), 0, libc::SEEK_CUR),
        )
    };
    let required_seals =
        libc::F_SEAL_SEAL | libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_WRITE;
    if descriptor_flags < 0
        || descriptor_flags & libc::FD_CLOEXEC == 0
        || seals < 0
        || seals & required_seals != required_seals
        || offset != 0
    {
        return Err(invalid_evidence_fd());
    }
    // SAFETY: stat points to initialized writable storage for fstat and fd is live.
    // reason: fstat validates the anonymous evidence descriptor type and size.
    #[allow(
        unsafe_code,
        reason = "fstat is required to validate the anonymous evidence file type and size"
    )]
    let metadata = unsafe {
        let mut stat: libc::stat = std::mem::zeroed();
        if libc::fstat(fd.as_raw_fd(), std::ptr::addr_of_mut!(stat)) != 0 {
            return Err(invalid_evidence_fd());
        }
        stat
    };
    if metadata.st_mode & libc::S_IFMT != libc::S_IFREG
        || u64::try_from(metadata.st_size).ok() != Some(bundle.byte_length)
    {
        return Err(invalid_evidence_fd());
    }
    if metadata.st_nlink != 0 {
        return Err(invalid_evidence_fd());
    }
    let file = File::from(fd.try_clone().map_err(|_| invalid_evidence_fd())?);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut total = 0_u64;
    loop {
        let read = file
            .read_at(&mut buffer, total)
            .map_err(|_| invalid_evidence_fd())?;
        if read == 0 {
            break;
        }
        total = total.saturating_add(read as u64);
        if total > bundle.byte_length {
            return Err(invalid_evidence_fd());
        }
        hasher.update(&buffer[..read]);
    }
    if total != bundle.byte_length || format!("{:x}", hasher.finalize()) != bundle.sha256 {
        return Err(invalid_evidence_fd());
    }
    Ok(())
}

pub fn create_unsealed_memfd(name: &str) -> Result<File, BrokerError> {
    let name = CString::new(name).map_err(|_| {
        BrokerError::new(
            ErrorCode::Internal,
            "attestation memfd name is invalid",
            false,
        )
    })?;
    // SAFETY: the C string is NUL-terminated and successful memfd_create
    // returns one new descriptor owned by the caller.
    // tpm2-tools writes quote artifacts to file paths, so the broker backs
    // those paths with anonymous memfd descriptors instead of filesystem state.
    // reason: anonymous quote output descriptors require Linux memfd_create.
    #[allow(
        unsafe_code,
        reason = "anonymous quote output descriptors require Linux memfd_create"
    )]
    let raw_fd =
        unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING) };
    if raw_fd < 0 {
        return Err(BrokerError::io(
            ErrorCode::Internal,
            "cannot create quote output descriptor",
            std::io::Error::last_os_error(),
        ));
    }
    // SAFETY: raw_fd was returned as a new descriptor and is converted once.
    // reason: the successful memfd_create result transfers exactly one owned descriptor.
    #[allow(unsafe_code, reason = "memfd_create transfers one owned descriptor")]
    let owned = unsafe { OwnedFd::from_raw_fd(raw_fd) };
    Ok(File::from(owned))
}

pub fn set_descriptor_cloexec(fd: RawFd, cloexec: bool) -> Result<(), BrokerError> {
    // SAFETY: F_GETFD/F_SETFD inspect and update descriptor flags only.
    // reason: tpm2_quote needs temporary inherited memfds addressed through /proc/self/fd.
    #[allow(
        unsafe_code,
        reason = "descriptor inheritance is controlled through fcntl FD_CLOEXEC"
    )]
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(BrokerError::io(
            ErrorCode::Internal,
            "cannot inspect descriptor flags",
            std::io::Error::last_os_error(),
        ));
    }
    let next_flags = if cloexec {
        flags | libc::FD_CLOEXEC
    } else {
        flags & !libc::FD_CLOEXEC
    };
    // SAFETY: F_SETFD updates the live descriptor's close-on-exec bit.
    // reason: see F_GETFD block above.
    #[allow(
        unsafe_code,
        reason = "descriptor inheritance is controlled through fcntl FD_CLOEXEC"
    )]
    let result = unsafe { libc::fcntl(fd, libc::F_SETFD, next_flags) };
    if result != 0 {
        return Err(BrokerError::io(
            ErrorCode::Internal,
            "cannot update descriptor flags",
            std::io::Error::last_os_error(),
        ));
    }
    Ok(())
}

pub fn create_sealed_memfd(bytes: &[u8]) -> Result<OwnedFd, BrokerError> {
    // SAFETY: the name is a static NUL-terminated string and successful
    // memfd_create returns one new descriptor owned by the caller.
    // reason: Linux memfd_create is required to build sealed evidence fixtures.
    #[allow(
        unsafe_code,
        reason = "sealed anonymous evidence fixtures require Linux memfd_create"
    )]
    let raw_fd = unsafe {
        libc::memfd_create(
            c"openburnbar-attestation-evidence".as_ptr(),
            libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
        )
    };
    if raw_fd < 0 {
        return Err(BrokerError::io(
            ErrorCode::Internal,
            "cannot create sealed evidence bundle",
            std::io::Error::last_os_error(),
        ));
    }
    // SAFETY: raw_fd was returned as a new descriptor and is converted once.
    // reason: the successful memfd_create result transfers exactly one owned descriptor.
    #[allow(unsafe_code, reason = "memfd_create transfers one owned descriptor")]
    let owned = unsafe { OwnedFd::from_raw_fd(raw_fd) };
    let mut file = File::from(owned);
    std::io::Write::write_all(&mut file, bytes).map_err(|source| {
        BrokerError::io(
            ErrorCode::Internal,
            "cannot write sealed evidence bundle",
            source,
        )
    })?;
    file.seek(SeekFrom::Start(0)).map_err(|source| {
        BrokerError::io(
            ErrorCode::Internal,
            "cannot rewind sealed evidence bundle",
            source,
        )
    })?;
    let seals = libc::F_SEAL_SEAL | libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_WRITE;
    // SAFETY: F_ADD_SEALS changes kernel metadata on the live memfd only.
    // reason: fcntl F_ADD_SEALS makes the evidence memfd immutable.
    #[allow(
        unsafe_code,
        reason = "memfd immutability is established through fcntl F_ADD_SEALS"
    )]
    let result = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_ADD_SEALS, seals) };
    if result != 0 {
        return Err(BrokerError::io(
            ErrorCode::Internal,
            "cannot seal evidence bundle",
            std::io::Error::last_os_error(),
        ));
    }
    Ok(file.into())
}

impl RequestAncillary {
    fn into_credentials(self) -> Result<PeerCredentials, BrokerError> {
        let has_rights = !self.rights.is_empty();
        if self.invalid || has_rights || self.credentials.len() != 1 {
            return Err(unauthorized(
                "request packet must contain exactly one credentials message and no other ancillary data",
            ));
        }
        self.credentials
            .into_iter()
            .next()
            .ok_or_else(|| unauthorized("request packet credentials are missing"))
    }
}

fn collect_request_ancillary(message: &libc::msghdr) -> RequestAncillary {
    let mut ancillary = RequestAncillary::default();
    // SAFETY: message was populated by a successful recvmsg call and its control
    // buffer remains live. Every received SCM_RIGHTS fd is immediately converted
    // to OwnedFd so all later success and error paths close it by RAII.
    // reason: libc CMSG traversal is required to validate and own received ancillary descriptors.
    #[allow(
        unsafe_code,
        reason = "parsing and owning Unix ancillary data requires libc CMSG traversal"
    )]
    unsafe {
        let control_start = message.msg_control as usize;
        let control_end = control_start.saturating_add(message.msg_controllen);
        let mut header = libc::CMSG_FIRSTHDR(message);
        while !header.is_null() {
            let base_length = libc::CMSG_LEN(0) as usize;
            let header_start = header as usize;
            if header_start < control_start
                || header_start.saturating_add(base_length) > control_end
            {
                ancillary.invalid = true;
                break;
            }
            let message_length = (*header).cmsg_len;
            let data_start = libc::CMSG_DATA(header) as usize;
            let available_data_length = control_end.saturating_sub(data_start);
            if message_length < base_length {
                ancillary.invalid = true;
            } else if (*header).cmsg_level == libc::SOL_SOCKET
                && (*header).cmsg_type == libc::SCM_RIGHTS
            {
                let declared_data_length = message_length - base_length;
                let data_length = declared_data_length.min(available_data_length);
                if declared_data_length > available_data_length {
                    ancillary.invalid = true;
                }
                if data_length == 0 || !data_length.is_multiple_of(std::mem::size_of::<RawFd>()) {
                    ancillary.invalid = true;
                }
                for index in 0..(data_length / std::mem::size_of::<RawFd>()) {
                    let raw = std::ptr::read_unaligned(
                        libc::CMSG_DATA(header).cast::<RawFd>().add(index),
                    );
                    if raw < 0 {
                        ancillary.invalid = true;
                    } else {
                        ancillary.rights.push(OwnedFd::from_raw_fd(raw));
                    }
                }
            } else if (*header).cmsg_level == libc::SOL_SOCKET
                && (*header).cmsg_type == libc::SCM_CREDENTIALS
            {
                let expected = libc::CMSG_LEN(std::mem::size_of::<libc::ucred>() as u32) as usize;
                if message_length != expected
                    || available_data_length < std::mem::size_of::<libc::ucred>()
                {
                    ancillary.invalid = true;
                } else {
                    let raw =
                        std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<libc::ucred>());
                    match u32::try_from(raw.pid) {
                        Ok(pid) if pid > 0 => ancillary.credentials.push(PeerCredentials {
                            pid,
                            uid: raw.uid,
                            gid: raw.gid,
                        }),
                        _ => ancillary.invalid = true,
                    }
                }
            } else {
                ancillary.invalid = true;
            }
            header = libc::CMSG_NXTHDR(message, header);
        }
    }
    ancillary
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

const fn invalid_evidence_fd() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationFailed,
        "attestation evidence descriptor is invalid",
        false,
    )
}

fn load_signed_manifest(
    manifest_path: &Path,
    signature_path: &Path,
    public_key_path: &Path,
) -> Result<LoadedInstalledManifest, BrokerError> {
    let manifest_bytes = read_root_owned_bounded_file(manifest_path, 0o644, MAX_MANIFEST_BYTES)?;
    let signature_bytes = read_root_owned_bounded_file(signature_path, 0o644, 64)?;
    let public_key_bytes = read_root_owned_bounded_file(public_key_path, 0o644, 4 * 1024)?;
    verify_manifest_signature(&manifest_bytes, &signature_bytes, &public_key_bytes)?;
    let release_digest_sha256 = format!("{:x}", Sha256::digest(&manifest_bytes));
    let manifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|_| manifest_signature_invalid("signed installed manifest is malformed"))?;
    Ok(LoadedInstalledManifest {
        manifest,
        release_digest_sha256,
    })
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
        || !valid_firebase_app_id(&manifest.firebase_app_id)
        || !valid_lower_hex(&manifest.git_commit, 40)
        || manifest.package_name != "open-burn-bar"
        || manifest.policy_id != "openburnbar-linux-tpm2-ima-v1"
        || manifest.broker_protocol_version != 2
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

fn valid_firebase_app_id(value: &str) -> bool {
    if value.len() > 160 {
        return false;
    }
    let mut parts = value.split(':');
    matches!(parts.next(), Some("1"))
        && parts.next().is_some_and(|project| {
            !project.is_empty() && project.bytes().all(|byte| byte.is_ascii_digit())
        })
        && matches!(parts.next(), Some("web"))
        && parts.next().is_some_and(|app| {
            !app.is_empty() && app.bytes().all(|byte| byte.is_ascii_alphanumeric())
        })
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
            firebase_app_id: "1:123456789:web:abcdef0123456789".to_owned(),
            git_commit: "b".repeat(40),
            package_name: "open-burn-bar".to_owned(),
            policy_id: "openburnbar-linux-tpm2-ima-v1".to_owned(),
            broker_protocol_version: 2,
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

    fn evidence_descriptor(bytes: &[u8]) -> EvidenceBundle {
        EvidenceBundle {
            descriptor_index: 0,
            format: crate::protocol::EVIDENCE_BUNDLE_FORMAT.to_owned(),
            byte_length: bytes.len() as u64,
            sha256: format!("{:x}", Sha256::digest(bytes)),
        }
    }

    fn seqpacket_pair() -> Result<(SeqpacketConnection, OwnedFd), std::io::Error> {
        let mut descriptors = [-1_i32; 2];
        // SAFETY: storage has room for exactly two descriptors and successful
        // socketpair initializes both as new owned descriptors.
        // reason: the SCM_RIGHTS transport test requires a real SOCK_SEQPACKET pair.
        #[allow(
            unsafe_code,
            reason = "SCM_RIGHTS transport tests require a real SOCK_SEQPACKET pair"
        )]
        let result = unsafe {
            libc::socketpair(
                libc::AF_UNIX,
                libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC,
                0,
                descriptors.as_mut_ptr(),
            )
        };
        if result != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: socketpair returned each descriptor as newly owned.
        // reason: the first successful socketpair result transfers one owned descriptor.
        #[allow(unsafe_code, reason = "socketpair transfers two owned descriptors")]
        let sender = unsafe { OwnedFd::from_raw_fd(descriptors[0]) };
        // SAFETY: the second descriptor is distinct and converted once.
        // reason: the second successful socketpair result transfers one distinct owned descriptor.
        #[allow(unsafe_code, reason = "socketpair transfers two owned descriptors")]
        let receiver = unsafe { OwnedFd::from_raw_fd(descriptors[1]) };
        Ok((SeqpacketConnection { fd: sender }, receiver))
    }

    fn open_fd_count() -> Result<usize, std::io::Error> {
        Ok(std::fs::read_dir("/proc/self/fd")?.count())
    }

    fn send_request_rights(
        socket: &OwnedFd,
        packet: &[u8],
        descriptors: &[RawFd],
    ) -> Result<(), std::io::Error> {
        let mut iov = libc::iovec {
            iov_base: packet.as_ptr().cast_mut().cast(),
            iov_len: packet.len(),
        };
        let control_bytes = if descriptors.is_empty() {
            0
        } else {
            // SAFETY: CMSG_SPACE is a pure size calculation for the payload length.
            // reason: libc CMSG_SPACE sizes the SCM_RIGHTS test control storage.
            #[allow(
                unsafe_code,
                reason = "SCM_RIGHTS test control storage uses libc CMSG sizing"
            )]
            unsafe {
                libc::CMSG_SPACE(
                    u32::try_from(std::mem::size_of_val(descriptors)).unwrap_or(u32::MAX),
                ) as usize
            }
        };
        let control_words = control_bytes.div_ceil(std::mem::size_of::<usize>());
        let mut control = vec![0_usize; control_words];
        // SAFETY: zero is a valid initial state for msghdr and live buffers follow.
        // reason: zero initialization is the valid starting state for the send msghdr.
        #[allow(unsafe_code, reason = "sendmsg requires a zeroed platform msghdr")]
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = std::ptr::addr_of_mut!(iov);
        message.msg_iovlen = 1;
        if !descriptors.is_empty() {
            message.msg_control = control.as_mut_ptr().cast();
            message.msg_controllen = control_bytes;
            // SAFETY: aligned control storage was sized for the complete fd slice.
            // reason: libc CMSG accessors construct the SCM_RIGHTS test header.
            #[allow(
                unsafe_code,
                reason = "SCM_RIGHTS test messages require constructing one CMSG header"
            )]
            unsafe {
                let header = libc::CMSG_FIRSTHDR(std::ptr::addr_of!(message));
                if header.is_null() {
                    return Err(std::io::Error::other("cannot construct SCM_RIGHTS header"));
                }
                (*header).cmsg_level = libc::SOL_SOCKET;
                (*header).cmsg_type = libc::SCM_RIGHTS;
                (*header).cmsg_len = libc::CMSG_LEN(
                    u32::try_from(std::mem::size_of_val(descriptors)).unwrap_or(u32::MAX),
                ) as usize;
                std::ptr::copy_nonoverlapping(
                    descriptors.as_ptr(),
                    libc::CMSG_DATA(header).cast::<RawFd>(),
                    descriptors.len(),
                );
            }
        }
        // SAFETY: message points to live packet/control buffers and the connected
        // socket remains owned for the duration of the call.
        // reason: sendmsg exercises request ancillary-data transport.
        #[allow(
            unsafe_code,
            reason = "request ancillary regression tests require sendmsg"
        )]
        let sent = unsafe { libc::sendmsg(socket.as_raw_fd(), &message, libc::MSG_NOSIGNAL) };
        if sent < 0 || usize::try_from(sent).ok() != Some(packet.len()) {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }

    fn receive_response_fd(
        socket: &OwnedFd,
    ) -> Result<(Vec<u8>, OwnedFd), Box<dyn std::error::Error>> {
        let mut bytes = [0_u8; 128];
        let mut control = [0_usize; 8];
        let mut iov = libc::iovec {
            iov_base: bytes.as_mut_ptr().cast(),
            iov_len: bytes.len(),
        };
        // SAFETY: zero initializes all unused msghdr fields; live buffers follow.
        // reason: zero initialization is the valid starting state for the receive msghdr.
        #[allow(unsafe_code, reason = "recvmsg requires a zeroed platform msghdr")]
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = std::ptr::addr_of_mut!(iov);
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = std::mem::size_of_val(&control);
        // SAFETY: message owns valid writable buffers and socket is connected.
        // reason: recvmsg receives the SCM_RIGHTS ancillary descriptor.
        #[allow(
            unsafe_code,
            reason = "receiving SCM_RIGHTS requires recvmsg ancillary data"
        )]
        let received = unsafe {
            libc::recvmsg(
                socket.as_raw_fd(),
                std::ptr::addr_of_mut!(message),
                libc::MSG_CMSG_CLOEXEC,
            )
        };
        if received < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: recvmsg populated a live control buffer. This test expects one
        // SCM_RIGHTS int and converts that received descriptor exactly once.
        // reason: libc CMSG accessors read and transfer ownership of the received descriptor.
        #[allow(
            unsafe_code,
            reason = "the received SCM_RIGHTS descriptor must be read from CMSG_DATA"
        )]
        let descriptor = unsafe {
            let header = libc::CMSG_FIRSTHDR(std::ptr::addr_of!(message));
            if header.is_null()
                || (*header).cmsg_level != libc::SOL_SOCKET
                || (*header).cmsg_type != libc::SCM_RIGHTS
            {
                return Err("response did not carry one SCM_RIGHTS descriptor".into());
            }
            OwnedFd::from_raw_fd(std::ptr::read(libc::CMSG_DATA(header).cast::<RawFd>()))
        };
        let length = usize::try_from(received)?;
        Ok((bytes[..length].to_vec(), descriptor))
    }

    #[test]
    fn sealed_memfd_validation_rejects_unsealed_oversized_and_digest_mismatch(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let bytes = b"sealed-evidence";
        let sealed = create_sealed_memfd(bytes)?;
        let descriptor = evidence_descriptor(bytes);
        assert!(validate_evidence_bundle_fd(&sealed, &descriptor).is_ok());

        let mut direct = File::from(sealed.try_clone()?);
        let mut direct_bytes = vec![0_u8; bytes.len()];
        direct.read_exact(&mut direct_bytes)?;
        assert_eq!(direct_bytes, bytes);

        let mut digest_mismatch = descriptor.clone();
        digest_mismatch.sha256 = "0".repeat(64);
        assert!(validate_evidence_bundle_fd(&sealed, &digest_mismatch).is_err());
        let mut oversized = descriptor.clone();
        oversized.byte_length = MAX_EVIDENCE_BUNDLE_BYTES + 1;
        assert!(validate_evidence_bundle_fd(&sealed, &oversized).is_err());

        let root = temp_dir("unsealed-evidence");
        let path = root.join("bundle");
        std::fs::write(&path, bytes)?;
        let unsealed = File::open(&path)?;
        let unsealed_fd: OwnedFd = unsealed.into();
        assert!(validate_evidence_bundle_fd(&unsealed_fd, &descriptor).is_err());
        std::fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn request_rights_and_truncation_are_rejected_without_fd_leaks(
    ) -> Result<(), Box<dyn std::error::Error>> {
        const ISOLATED_ENV: &str = "OPENBURNBAR_ATTESTD_FD_LEAK_TEST_CHILD";
        if env::var_os(ISOLATED_ENV).is_none() {
            let status = std::process::Command::new(std::env::current_exe()?)
                .args([
                    "--exact",
                    "linux::tests::request_rights_and_truncation_are_rejected_without_fd_leaks",
                    "--test-threads=1",
                ])
                .env(ISOLATED_ENV, "1")
                .status()?;
            assert!(status.success());
            return Ok(());
        }
        for descriptor_count in [1_usize, 2, 64] {
            let (receiver, sender) = seqpacket_pair()?;
            set_pass_credentials(receiver.fd.as_raw_fd())?;
            let descriptors = (0..descriptor_count)
                .map(|index| create_sealed_memfd(format!("evidence-{index}").as_bytes()))
                .collect::<Result<Vec<_>, _>>()?;
            let raw_descriptors = descriptors
                .iter()
                .map(AsRawFd::as_raw_fd)
                .collect::<Vec<_>>();
            let before_receive = open_fd_count()?;
            send_request_rights(&sender, b"request", &raw_descriptors)?;
            let error = receiver.receive_request().err().map(|value| value.code());
            assert_eq!(error, Some(ErrorCode::UnauthorizedPeer));
            assert_eq!(open_fd_count()?, before_receive);
        }
        Ok(())
    }

    #[test]
    fn response_and_one_descriptor_are_one_record_without_fd_leak(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let (sender, receiver) = seqpacket_pair()?;
        let packet = b"framed-json-response";
        let bytes = b"sealed-evidence";
        let evidence = create_sealed_memfd(bytes)?;
        let original_raw_fd = evidence.as_raw_fd();
        sender.send_response(packet, Some(&evidence))?;
        drop(evidence);
        // SAFETY: F_GETFD only queries whether the old descriptor number remains open.
        // reason: fcntl F_GETFD proves the dropped descriptor is closed.
        #[allow(
            unsafe_code,
            reason = "fd leak regression checks the dropped descriptor"
        )]
        let dropped_result = unsafe { libc::fcntl(original_raw_fd, libc::F_GETFD) };
        assert_eq!(dropped_result, -1);

        let (received_packet, received_fd) = receive_response_fd(&receiver)?;
        assert_eq!(received_packet, packet);
        assert!(validate_evidence_bundle_fd(&received_fd, &evidence_descriptor(bytes)).is_ok());
        Ok(())
    }

    #[test]
    fn response_transport_rejects_two_descriptors() -> Result<(), Box<dyn std::error::Error>> {
        let (sender, _receiver) = seqpacket_pair()?;
        let first = create_sealed_memfd(b"first")?;
        let second = create_sealed_memfd(b"second")?;
        assert_eq!(
            sender
                .send_response_fds(b"response", &[first.as_raw_fd(), second.as_raw_fd()])
                .err()
                .map(|error| error.code()),
            Some(ErrorCode::AttestationFailed)
        );
        Ok(())
    }
}
