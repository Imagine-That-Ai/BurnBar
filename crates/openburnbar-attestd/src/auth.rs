use crate::error::BrokerError;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PeerCredentials {
    pub pid: u32,
    pub uid: u32,
    pub gid: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizedPeer {
    pub credentials: PeerCredentials,
    pub executable_sha256: String,
    pub installed_release: InstalledReleaseIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstalledReleaseIdentity {
    pub firebase_app_id: String,
    pub app_version: String,
    pub architecture: String,
    pub release_digest_sha256: String,
    pub policy_id: String,
    pub attestation_kind: String,
}

pub trait PeerAuthorizer: Send + Sync {
    fn authorize(&self, peer: PeerCredentials) -> Result<AuthorizedPeer, BrokerError>;
}
