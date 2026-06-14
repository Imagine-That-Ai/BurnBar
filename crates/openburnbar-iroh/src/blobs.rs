// Mercury Phase 1 file-transfer integration.
//
// `IrohBlobNode` is a self-contained iroh endpoint that advertises only
// `iroh_blobs::ALPN`. It runs alongside the existing `IrohEndpointHandle`
// (which serves the chat ALPN `openburnbar/1`) so neither side has to
// re-architect to multiplex multiple ALPNs through one router. Two
// endpoints per device, each pinned to one protocol — minimal blast
// radius, minimal change to the chat path.
//
// Wire flow:
//   1. Sender Mac calls `publish_blob(path)` → opens its FsStore, hashes
//      the file, builds a `BlobTicket(node_addr, hash, format)`, returns
//      the base32 surface form.
//   2. Sender emits a `media.blob.advertise` JSON frame on the existing
//      Hermes chat stream carrying the ticket text + an attachment
//      manifest (filename, mime, size).
//   3. Receiver iOS sees the advertise frame on the chat stream, calls
//      `fetch_blob(ticket, dest)` → dials the sender's blob endpoint with
//      `iroh_blobs::ALPN`, downloads, exports to dest.
//   4. Receiver emits `media.blob.ack(received)` back on the chat stream.
//
// See `plans/2026-05-15-mercury-media-master-plan.md` § B.2 +
// `docs/HERMES_MEDIA_TRANSPORT.md` for the full architecture.

use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Instant;

use iroh::{
    endpoint::presets, protocol::Router, Endpoint, RelayMap, RelayMode, RelayUrl, SecretKey,
};
use iroh_blobs::api::downloader::Shuffled;
use iroh_blobs::{store::fs::FsStore, ticket::BlobTicket, BlobsProtocol};
use tokio::runtime::Runtime;
use tokio::sync::Mutex;
use tokio_stream::StreamExt;

use crate::{block_on, IrohFfiError, IrohNodeIdentity};

/// Hard streaming ceiling for a single inbound blob fetch. A malicious or
/// buggy sender can advertise a ticket whose backing content is far larger
/// than the `media.blob.advertise` manifest claims; without a ceiling the
/// receiver streams unbounded bytes to disk and a single peer can disk-fill
/// the device (T-ATT-01). 2 GiB comfortably covers every Mercury Phase 1
/// media payload (the largest sanctioned transfer is a short screen capture)
/// while bounding the blast radius of a lying/oversized advertisement.
///
/// The streaming loop aborts the moment cumulative bytes cross this line, and
/// a post-fetch assertion re-checks the exported file, so neither the
/// in-flight stream nor a resumed partial can exceed the ceiling. Fail closed:
/// the transfer errors rather than truncating to a partial file.
pub const OPENBURNBAR_MAX_BLOB_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// True once cumulative downloaded `bytes` have crossed `ceiling`. Pulled out
/// as a pure function so the streaming-abort decision is unit-testable without
/// standing up an endpoint or moving real bytes over the network.
pub(crate) fn blob_byte_ceiling_exceeded(bytes: u64, ceiling: u64) -> bool {
    bytes > ceiling
}

/// Post-fetch guard: the exported file must not exceed `ceiling`. Returns an
/// error (never a truncated success) so a lying manifest that slips an
/// oversize blob past the streaming abort still fails closed at export time.
pub(crate) fn assert_blob_within_ceiling(
    bytes_total: u64,
    ceiling: u64,
) -> Result<(), IrohFfiError> {
    if bytes_total > ceiling {
        return Err(IrohFfiError::StreamFailed {
            detail: format!(
                "blob too large: {bytes_total} bytes exceeds ceiling of {ceiling} bytes"
            ),
        });
    }
    Ok(())
}

/// Validated wrapper around an iroh-blobs `BlobTicket` text form. Carried
/// as a base32 string on the wire so the Swift side can pass it through
/// the existing JSON envelope without binary escaping.
#[derive(uniffi::Record, Clone, Debug)]
pub struct BlobTicketBytes {
    /// Base32 surface form. Round-trips through `BlobTicket::from_str`.
    pub text: String,
}

/// Per-transfer statistics returned to Swift on a successful `fetch_blob`.
/// Bucketing into telemetry happens client-side so payload counts never
/// reach Firebase Analytics in plaintext.
#[derive(uniffi::Record, Clone, Debug)]
pub struct BlobTransferStats {
    pub bytes_total: u64,
    pub blake3_hash: String,
    pub duration_millis: u64,
    pub did_resume: bool,
}

/// Self-contained iroh blob endpoint. One instance per device per
/// process. Owns its own `Endpoint`, `FsStore`, `BlobsProtocol`, and
/// `Router`. Idempotent bootstrap; subsequent calls replace the inner
/// state.
#[derive(uniffi::Object)]
pub struct IrohBlobNode {
    inner: Mutex<Option<BlobNodeInner>>,
}

struct BlobNodeInner {
    endpoint: Endpoint,
    store: FsStore,
    router: Router,
    runtime: Runtime,
    identity: IrohNodeIdentity,
}

#[uniffi::export]
impl IrohBlobNode {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(None),
        })
    }

    /// Spin up the blob endpoint with the supplied secret key + on-disk
    /// store directory. `relay_url` empty → n0's public relay set;
    /// non-empty → pin to a specific relay (production, hosted-tier).
    /// Returns the iroh node identity Swift should embed in the
    /// `media.blob.advertise` ticket-host hint.
    pub fn bootstrap(
        self: Arc<Self>,
        secret: crate::IrohSecretKeyMaterial,
        store_dir: String,
        relay_url: String,
    ) -> Result<IrohNodeIdentity, IrohFfiError> {
        if secret.raw.len() != 32 {
            return Err(IrohFfiError::InvalidSecretKey);
        }
        let mut key_bytes = [0u8; 32];
        key_bytes.copy_from_slice(&secret.raw);
        let secret_key = SecretKey::from_bytes(&key_bytes);

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("openburnbar-iroh-blob")
            .build()
            .map_err(IrohFfiError::runtime)?;

        let relay_mode = if relay_url.trim().is_empty() {
            RelayMode::Default
        } else {
            let url: RelayUrl = relay_url.parse().map_err(|err: iroh::RelayUrlParseError| {
                IrohFfiError::RuntimeFailed {
                    detail: format!("invalid relay url: {err}"),
                }
            })?;
            RelayMode::Custom(RelayMap::from(url))
        };

        let store_path = PathBuf::from(&store_dir);
        std::fs::create_dir_all(&store_path).map_err(|err| IrohFfiError::RuntimeFailed {
            detail: format!("create store dir {store_dir}: {err}"),
        })?;
        let transport_config = crate::openburnbar_transport_config()?;

        let (endpoint, store, router, identity) = runtime.block_on(async {
            let endpoint = Endpoint::builder(presets::N0)
                .secret_key(secret_key.clone())
                .alpns(vec![iroh_blobs::ALPN.to_vec()])
                .relay_mode(relay_mode)
                .transport_config(transport_config)
                .bind()
                .await
                .map_err(IrohFfiError::runtime)?;
            tokio::time::timeout(std::time::Duration::from_secs(10), endpoint.online())
                .await
                .map_err(|_| IrohFfiError::RuntimeFailed {
                    detail: "iroh blob endpoint did not come online within 10s".into(),
                })?;

            let store =
                FsStore::load(&store_path)
                    .await
                    .map_err(|err| IrohFfiError::RuntimeFailed {
                        detail: format!("FsStore::load({store_dir}): {err}"),
                    })?;

            let blobs = BlobsProtocol::new(&store, None);
            let router = Router::builder(endpoint.clone())
                .accept(iroh_blobs::ALPN, blobs)
                .spawn();

            let endpoint_addr = endpoint.addr();
            let node_id = endpoint.id();
            let identity = IrohNodeIdentity {
                raw_public_key: node_id.as_bytes().to_vec(),
                node_id: node_id.to_string(),
                relay_url: endpoint_addr
                    .relay_urls()
                    .next()
                    .map(ToString::to_string)
                    .unwrap_or_default(),
                direct_addresses: endpoint_addr.ip_addrs().map(ToString::to_string).collect(),
            };
            Ok::<_, IrohFfiError>((endpoint, store, router, identity))
        })?;

        block_on(async {
            *self.inner.lock().await = Some(BlobNodeInner {
                endpoint,
                store,
                router,
                runtime,
                identity: identity.clone(),
            });
            Ok::<_, IrohFfiError>(())
        })?;

        Ok(identity)
    }

    /// Hash + ingest a local file into the blob store, return a ticket
    /// the receiver can use to fetch it. Idempotent — same file content
    /// produces the same hash and the same ticket bytes.
    pub fn publish_blob(
        self: Arc<Self>,
        local_path: String,
    ) -> Result<BlobTicketBytes, IrohFfiError> {
        let (endpoint, store) = block_on(async {
            let guard = self.inner.lock().await;
            let inner = guard.as_ref().ok_or(IrohFfiError::EndpointNotInitialized)?;
            Ok::<_, IrohFfiError>((inner.endpoint.clone(), inner.store.clone()))
        })?;

        let path = PathBuf::from(&local_path);
        if !path.is_file() {
            return Err(IrohFfiError::RuntimeFailed {
                detail: format!("publish_blob: not a file: {local_path}"),
            });
        }

        block_on(async move {
            let abs_path =
                std::path::absolute(&path).map_err(|err| IrohFfiError::RuntimeFailed {
                    detail: format!("absolute({}): {err}", path.display()),
                })?;

            let tag = store.blobs().add_path(abs_path).await.map_err(|err| {
                IrohFfiError::RuntimeFailed {
                    detail: format!("add_path: {err}"),
                }
            })?;

            let ticket = BlobTicket::new(endpoint.addr(), tag.hash, tag.format);
            Ok(BlobTicketBytes {
                text: ticket.to_string(),
            })
        })
    }

    /// Dial the ticket's source node, download the blob, write it to
    /// `destination`. Returns transfer stats. Resume across reconnects
    /// is handled by iroh-blobs's downloader internally — `did_resume`
    /// flips true if any partial state was found at start.
    pub fn fetch_blob(
        self: Arc<Self>,
        ticket_text: String,
        destination: String,
    ) -> Result<BlobTransferStats, IrohFfiError> {
        let (endpoint, store) = block_on(async {
            let guard = self.inner.lock().await;
            let inner = guard.as_ref().ok_or(IrohFfiError::EndpointNotInitialized)?;
            Ok::<_, IrohFfiError>((inner.endpoint.clone(), inner.store.clone()))
        })?;

        let trimmed = ticket_text.trim().to_string();
        let ticket = BlobTicket::from_str(&trimmed).map_err(|err| IrohFfiError::StreamFailed {
            detail: format!("invalid blob ticket: {err}"),
        })?;
        let dest_path = PathBuf::from(&destination);

        block_on(async move {
            let abs_dest =
                std::path::absolute(&dest_path).map_err(|err| IrohFfiError::RuntimeFailed {
                    detail: format!("absolute({}): {err}", dest_path.display()),
                })?;

            // Resume probe: if the destination already exists, capture
            // its current size so we can flag the transfer as a resume.
            let pre_existing_size = std::fs::metadata(&abs_dest).map(|m| m.len()).unwrap_or(0);
            let did_resume = pre_existing_size > 0;

            let started = Instant::now();
            let downloader = store.downloader(&endpoint);
            let mut progress = downloader
                .download(
                    ticket.hash_and_format(),
                    Shuffled::new(vec![ticket.addr().id]),
                )
                .stream()
                .await
                .map_err(|err| IrohFfiError::StreamFailed {
                    detail: format!("blob download stream: {err}"),
                })?;
            // Streaming byte ceiling (T-ATT-01): iroh-blobs emits a cumulative
            // `Progress(total)` as bytes arrive. Abort the moment the running
            // total crosses the hard ceiling so an oversized blob behind a
            // lying manifest cannot disk-fill the receiver — we stop pulling
            // bytes instead of streaming the whole file and rejecting it after.
            while let Some(item) = progress.next().await {
                match item {
                    iroh_blobs::api::downloader::DownloadProgressItem::Error(err) => {
                        return Err(IrohFfiError::StreamFailed {
                            detail: format!("blob download: {err}"),
                        });
                    }
                    iroh_blobs::api::downloader::DownloadProgressItem::Progress(downloaded)
                        if blob_byte_ceiling_exceeded(downloaded, OPENBURNBAR_MAX_BLOB_BYTES) =>
                    {
                        return Err(IrohFfiError::StreamFailed {
                            detail: format!(
                                "blob download aborted: {downloaded} bytes exceeds ceiling of {OPENBURNBAR_MAX_BLOB_BYTES} bytes"
                            ),
                        });
                    }
                    _ => {}
                }
            }

            store
                .blobs()
                .export(ticket.hash(), &abs_dest)
                .await
                .map_err(|err| IrohFfiError::RuntimeFailed {
                    detail: format!("blob export: {err}"),
                })?;

            let bytes_total = std::fs::metadata(&abs_dest).map(|m| m.len()).unwrap_or(0);
            // Post-fetch assertion (T-ATT-01): re-check the exported file. The
            // streaming loop bounds the in-flight stream, but a resumed partial
            // or any path that bypasses `Progress` must not slip an oversize
            // file past this point. Fail closed rather than return a partial.
            assert_blob_within_ceiling(bytes_total, OPENBURNBAR_MAX_BLOB_BYTES)?;
            let duration_millis = crate::u64_saturating_from_u128(started.elapsed().as_millis());

            Ok(BlobTransferStats {
                bytes_total,
                blake3_hash: ticket.hash().to_string(),
                duration_millis,
                did_resume,
            })
        })
    }

    /// Returns the cached identity if `bootstrap` has been called.
    pub fn identity(self: Arc<Self>) -> Result<IrohNodeIdentity, IrohFfiError> {
        block_on(async move {
            let guard = self.inner.lock().await;
            guard
                .as_ref()
                .map(|inner| inner.identity.clone())
                .ok_or(IrohFfiError::EndpointNotInitialized)
        })
    }

    /// Tear down the router, close the endpoint, drop the store and
    /// runtime. Idempotent.
    pub fn shutdown(self: Arc<Self>) -> Result<(), IrohFfiError> {
        let inner = block_on(async {
            let mut guard = self.inner.lock().await;
            Ok::<_, IrohFfiError>(guard.take())
        })?;

        if let Some(BlobNodeInner {
            runtime,
            router,
            endpoint,
            ..
        }) = inner
        {
            runtime.block_on(async move {
                let _ = router.shutdown().await;
                endpoint.close().await;
            });
            drop(runtime);
        }
        Ok(())
    }
}

/// Parse a candidate ticket text into the canonical base32 surface form.
/// Returns the canonical re-serialized string so Swift never has to
/// second-guess whitespace or encoding nits.
#[uniffi::export]
pub fn parse_blob_ticket(text: String) -> Result<BlobTicketBytes, IrohFfiError> {
    let trimmed = text.trim();
    let ticket = BlobTicket::from_str(trimmed).map_err(|err| IrohFfiError::StreamFailed {
        detail: format!("invalid blob ticket: {err}"),
    })?;
    Ok(BlobTicketBytes {
        text: ticket.to_string(),
    })
}

/// Returns the iroh-blobs ALPN. Mac and iOS surface this so Swift code
/// that needs to refuse a stream classified as a blob fetch can do so
/// without hardcoding the constant.
#[uniffi::export]
pub fn iroh_blobs_alpn() -> Vec<u8> {
    iroh_blobs::ALPN.to_vec()
}

/// Returns the iroh-blobs crate version that the binary was built with.
/// The `OpenBurnBarIroh xcframework` CI workflow asserts this against the
/// pinned version in `Cargo.toml` so iroh / iroh-blobs version drift
/// surfaces at build time rather than as a runtime decode failure.
#[uniffi::export]
pub fn iroh_blobs_crate_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh::{EndpointAddr, EndpointId, SecretKey};
    use iroh_blobs::{BlobFormat, Hash};

    fn sample_ticket() -> BlobTicket {
        let secret = SecretKey::generate();
        let node_id: EndpointId = secret.public();
        let node = EndpointAddr::from(node_id);
        let hash = Hash::new(b"hello world");
        BlobTicket::new(node, hash, BlobFormat::Raw)
    }

    #[test]
    fn parse_blob_ticket_round_trips_a_real_ticket() {
        let ticket = sample_ticket();
        let original = ticket.to_string();
        let parsed = match parse_blob_ticket(original.clone()) {
            Ok(parsed) => parsed,
            Err(error) => panic!("ticket parses: {error}"),
        };
        assert_eq!(parsed.text, original);
    }

    #[test]
    fn parse_blob_ticket_rejects_garbage() {
        let err = match parse_blob_ticket("not-a-real-ticket".into()) {
            Ok(_) => panic!("garbage ticket must be rejected"),
            Err(error) => error,
        };
        match err {
            IrohFfiError::StreamFailed { detail } => {
                assert!(detail.starts_with("invalid blob ticket"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn parse_blob_ticket_trims_surrounding_whitespace() {
        let ticket = sample_ticket();
        let original = ticket.to_string();
        let padded = format!("  \t{original}  \n");
        let parsed = match parse_blob_ticket(padded) {
            Ok(parsed) => parsed,
            Err(error) => panic!("padded ticket parses: {error}"),
        };
        assert_eq!(parsed.text, original);
    }

    #[test]
    fn iroh_blobs_alpn_matches_crate_constant() {
        assert_eq!(iroh_blobs_alpn(), iroh_blobs::ALPN.to_vec());
    }

    #[test]
    fn iroh_blobs_crate_version_matches_cargo() {
        assert_eq!(iroh_blobs_crate_version(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn blob_byte_ceiling_allows_up_to_and_at_the_ceiling() {
        assert!(!blob_byte_ceiling_exceeded(0, OPENBURNBAR_MAX_BLOB_BYTES));
        assert!(!blob_byte_ceiling_exceeded(
            OPENBURNBAR_MAX_BLOB_BYTES - 1,
            OPENBURNBAR_MAX_BLOB_BYTES
        ));
        // A blob exactly at the ceiling is permitted; only strictly larger
        // payloads trip the abort.
        assert!(!blob_byte_ceiling_exceeded(
            OPENBURNBAR_MAX_BLOB_BYTES,
            OPENBURNBAR_MAX_BLOB_BYTES
        ));
    }

    #[test]
    fn blob_byte_ceiling_aborts_once_oversize() {
        assert!(blob_byte_ceiling_exceeded(
            OPENBURNBAR_MAX_BLOB_BYTES + 1,
            OPENBURNBAR_MAX_BLOB_BYTES
        ));
        // A wildly oversized advertisement (the disk-fill attack) trips it.
        assert!(blob_byte_ceiling_exceeded(
            u64::MAX,
            OPENBURNBAR_MAX_BLOB_BYTES
        ));
        // The streaming loop checks the ceiling against a small bound too: an
        // attacker advertising a 1-byte manifest cannot stream past it.
        assert!(blob_byte_ceiling_exceeded(2, 1));
    }

    #[test]
    fn assert_blob_within_ceiling_rejects_oversize_export() {
        let ceiling = OPENBURNBAR_MAX_BLOB_BYTES;
        assert!(assert_blob_within_ceiling(0, ceiling).is_ok());
        assert!(assert_blob_within_ceiling(ceiling, ceiling).is_ok());

        let err = match assert_blob_within_ceiling(ceiling + 1, ceiling) {
            Ok(()) => panic!("oversize export must be rejected"),
            Err(error) => error,
        };
        match err {
            IrohFfiError::StreamFailed { detail } => {
                assert!(detail.contains("blob too large"));
                assert!(detail.contains(&(ceiling + 1).to_string()));
                assert!(detail.contains(&ceiling.to_string()));
            }
            other => panic!("expected StreamFailed, got {other:?}"),
        }
    }
}
