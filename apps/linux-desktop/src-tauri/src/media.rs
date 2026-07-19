use serde::Serialize;
use std::io::{ErrorKind, Read};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const MEDIA_SOCKET_NAME: &str = "openburnbar-media.sock";
const FRAME_HEADER_BYTES: usize = 10;

#[derive(Debug, Clone)]
pub struct MediaFrame {
    pub kind: u8,
    pub flags: u8,
    pub pts_ms: u64,
    pub payload: Vec<u8>,
}

/// Shell-owned Mercury viewer capability. This is deliberately distinct from
/// the daemon's capture capability: a daemon may be able to encode frames
/// while the desktop shell is missing a native video sink to display them.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MediaViewerCapability {
    pub available: bool,
    pub renderer: &'static str,
    pub feature_enabled: bool,
    pub can_decode_vp9: bool,
    pub has_video_sink: bool,
    /// Stable machine-readable state used by the typed media status bridge.
    /// Keep this distinct from the human-facing install hint so diagnostics
    /// and UI copy can evolve independently.
    pub status: &'static str,
    pub reason: Option<String>,
    pub install_hint: Option<&'static str>,
}

pub struct MediaViewer {
    inner: Arc<Mutex<MediaViewerInner>>,
}

struct MediaViewerInner {
    received_frames: u64,
    open: bool,
    #[cfg(feature = "media-gst")]
    decoder: Option<openburnbar_media::DecodePipeline>,
    #[cfg(feature = "media-gst")]
    awaiting_keyframe: bool,
}

impl Default for MediaViewerInner {
    fn default() -> Self {
        Self {
            received_frames: 0,
            open: false,
            #[cfg(feature = "media-gst")]
            decoder: None,
            #[cfg(feature = "media-gst")]
            awaiting_keyframe: true,
        }
    }
}

impl MediaViewer {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(MediaViewerInner::default())),
        }
    }

    /// Report whether this shell can render Mercury VP9 frames. The probe is
    /// side-effect free: it initializes GStreamer and inspects registered
    /// factories, but does not create a pipeline or open a native window.
    pub fn capability() -> MediaViewerCapability {
        #[cfg(feature = "media-gst")]
        {
            let capabilities = openburnbar_media::viewer_probe();
            let (status, reason, install_hint) = if capabilities.available() {
                ("available", None, None)
            } else if !capabilities.backend_available {
                (
                    "gstreamer_backend_unavailable",
                    Some("gstreamer_backend_unavailable".to_string()),
                    Some("Install the GStreamer 1.0 runtime, then restart OpenBurnBar."),
                )
            } else if !capabilities.vp9_decoder_available {
                (
                    "gstreamer_vp9_decoder_missing",
                    Some("gstreamer_vp9_decoder_missing".to_string()),
                    Some("Install a GStreamer VP9 decoder plugin (for example gstreamer1.0-libav), then restart OpenBurnBar."),
                )
            } else {
                (
                    "gstreamer_video_sink_missing",
                    Some("gstreamer_video_sink_missing".to_string()),
                    Some("Install a native GStreamer video sink (for example gstreamer1.0-plugins-good), then restart OpenBurnBar."),
                )
            };
            return MediaViewerCapability {
                available: capabilities.available(),
                renderer: "media-gst",
                feature_enabled: true,
                can_decode_vp9: capabilities.vp9_decoder_available,
                has_video_sink: capabilities.video_sink_available,
                status,
                reason,
                install_hint,
            };
        }

        #[cfg(not(feature = "media-gst"))]
        {
            MediaViewerCapability {
                available: false,
                renderer: "stub",
                feature_enabled: false,
                can_decode_vp9: false,
                has_video_sink: false,
                status: "built_without_gstreamer",
                reason: Some("linux_media_viewer_built_without_gstreamer".to_string()),
                install_hint: Some(
                    "Install the packaged Linux build with GStreamer support, or rebuild with --features media-gst.",
                ),
            }
        }
    }

    pub fn ensure_window(&self, app: &AppHandle) {
        let mut inner = match self.inner.lock() {
            Ok(guard) => guard,
            Err(_) => return,
        };
        if inner.open {
            return;
        }
        #[cfg(feature = "media-gst")]
        let (decoder, decoder_error) = match openburnbar_media::DecodePipeline::new(
            "vp9",
            openburnbar_media::DecodeSinkMode::Auto,
        ) {
            Ok(decoder) => (Some(decoder), None),
            Err(error) => {
                eprintln!("openburnbar media viewer decoder unavailable: {error}");
                (None, Some(error.to_string()))
            }
        };

        #[cfg(feature = "media-gst")]
        {
            inner.decoder = decoder;
            inner.awaiting_keyframe = true;
        }
        inner.open = true;
        #[cfg(feature = "media-gst")]
        let ready_payload = serde_json::json!({
            "source": if cfg!(feature = "media-gst") { "media-gst" } else { "stub" },
            "available": decoder_error.is_none(),
            "featureEnabled": true,
            "reason": decoder_error,
        });
        #[cfg(not(feature = "media-gst"))]
        let ready_payload = serde_json::json!({
            "source": "stub",
            "available": false,
            "featureEnabled": false,
            "reason": "Linux media viewer was built without the GStreamer feature.",
        });
        let _ = app.emit("media-viewer-ready", ready_payload);
        #[cfg(not(feature = "media-gst"))]
        eprintln!("openburnbar media viewer stub: native GTK viewer window seam opened");
    }

    pub fn close_window(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.open = false;
            #[cfg(feature = "media-gst")]
            {
                if let Some(decoder) = inner.decoder.take() {
                    let _ = decoder.stop();
                }
                inner.awaiting_keyframe = true;
            }
        }
    }

    pub fn render_frame(&self, frame: &MediaFrame) {
        let Ok(mut inner) = self.inner.lock() else {
            return;
        };
        inner.received_frames += 1;
        #[cfg(feature = "media-gst")]
        {
            // The daemon currently sends VP9 video NAL frames over this
            // socket. Ignore future audio/control frames until their native
            // sinks are wired rather than feeding them to a video decoder.
            const VIDEO_NAL_KIND: u8 = 0x01;
            const KEYFRAME_FLAG: u8 = 1 << 0;
            if !inner.open || frame.kind != VIDEO_NAL_KIND {
                return;
            }
            if inner.awaiting_keyframe && frame.flags & KEYFRAME_FLAG == 0 {
                return;
            }
            let decode_error = match inner.decoder.as_ref() {
                Some(decoder) => decoder
                    .push_frame(&frame.payload, frame.pts_ms, frame.flags)
                    .err(),
                None => return,
            };
            if let Some(error) = decode_error {
                eprintln!("openburnbar media viewer decode failed: {error}");
                // A transient bus/pipeline error must not leave an otherwise
                // healthy socket session with a permanently dead viewer. The
                // decoder can be reset to NULL/Playing and will then accept a
                // fresh keyframe from the same stream. Only tear it down when
                // that recovery path fails.
                let restart_error = inner
                    .decoder
                    .as_ref()
                    .and_then(|decoder| decoder.restart().err());
                if let Some(restart_error) = restart_error {
                    eprintln!("openburnbar media viewer decoder restart failed: {restart_error}");
                    let decoder = inner.decoder.take();
                    drop(inner);
                    if let Some(decoder) = decoder {
                        let _ = decoder.stop();
                    }
                } else {
                    inner.awaiting_keyframe = true;
                    return;
                }
                return;
            }
            inner.awaiting_keyframe = false;
        }
        #[cfg(not(feature = "media-gst"))]
        eprintln!(
            "openburnbar media viewer stub: frame kind={} flags={} pts_ms={} bytes={}",
            frame.kind,
            frame.flags,
            frame.pts_ms,
            frame.payload.len()
        );
    }
}

pub fn start_media_socket_reader(app: AppHandle) {
    thread::Builder::new()
        .name("openburnbar-media-socket-reader".to_string())
        .spawn(move || {
            let viewer = MediaViewer::new();
            loop {
                match media_socket_path() {
                    Some(path) => read_media_socket(app.clone(), path, &viewer),
                    None => {
                        eprintln!("openburnbar media socket unavailable: XDG_RUNTIME_DIR is unset")
                    }
                }
                thread::sleep(Duration::from_millis(500));
            }
        })
        .expect("failed to spawn media socket reader");
}

fn media_socket_path() -> Option<PathBuf> {
    std::env::var_os("XDG_RUNTIME_DIR").map(|dir| PathBuf::from(dir).join(MEDIA_SOCKET_NAME))
}

fn read_media_socket(app: AppHandle, path: PathBuf, viewer: &MediaViewer) {
    match UnixStream::connect(&path) {
        Ok(mut stream) => {
            viewer.ensure_window(&app);
            loop {
                match read_frame(&mut stream) {
                    Ok(frame) => {
                        let _ = app.emit(
                            "media-frame-received",
                            serde_json::json!({
                                "kind": frame.kind,
                                "flags": frame.flags,
                                "ptsMs": frame.pts_ms,
                                "byteLength": frame.payload.len()
                            }),
                        );
                        viewer.render_frame(&frame);
                    }
                    Err(e) if e.kind() == ErrorKind::UnexpectedEof => {
                        viewer.close_window();
                        eprintln!("openburnbar media socket closed: {}", path.display());
                        break;
                    }
                    Err(e) => {
                        viewer.close_window();
                        eprintln!("openburnbar media socket read failed: {e}");
                        break;
                    }
                }
            }
        }
        Err(e) => {
            eprintln!(
                "openburnbar media socket not connected at {}: {e}",
                path.display()
            );
        }
    }
}

fn read_frame(stream: &mut UnixStream) -> std::io::Result<MediaFrame> {
    const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
    let mut prefix = [0_u8; 4];
    stream.read_exact(&mut prefix)?;
    let len = u32::from_be_bytes(prefix) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            ErrorKind::InvalidData,
            "media frame exceeds size limit",
        ));
    }
    let mut body = vec![0_u8; len];
    stream.read_exact(&mut body)?;
    if body.len() < FRAME_HEADER_BYTES {
        return Err(std::io::Error::new(
            ErrorKind::InvalidData,
            "media frame shorter than protocol header",
        ));
    }
    let kind = body[0];
    let flags = body[1];
    let mut pts = [0_u8; 8];
    pts.copy_from_slice(&body[2..10]);
    Ok(MediaFrame {
        kind,
        flags,
        pts_ms: u64::from_be_bytes(pts),
        payload: body[10..].to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::{read_frame, MediaFrame, FRAME_HEADER_BYTES};
    use std::io::Write;
    use std::os::unix::net::UnixStream;

    fn encode_frame(kind: u8, flags: u8, pts_ms: u64, payload: &[u8]) -> Vec<u8> {
        let body_len = FRAME_HEADER_BYTES + payload.len();
        let mut bytes = Vec::with_capacity(4 + body_len);
        bytes.extend_from_slice(&(body_len as u32).to_be_bytes());
        bytes.push(kind);
        bytes.push(flags);
        bytes.extend_from_slice(&pts_ms.to_be_bytes());
        bytes.extend_from_slice(payload);
        bytes
    }

    #[test]
    fn read_frame_decodes_shell_envelope() {
        let (mut writer, mut reader) = UnixStream::pair().expect("socket pair");
        writer
            .write_all(&encode_frame(0x01, 0x01, 42, b"vp9"))
            .expect("write frame");

        let frame = read_frame(&mut reader).expect("decode frame");
        assert_eq!(frame.kind, 0x01);
        assert_eq!(frame.flags, 0x01);
        assert_eq!(frame.pts_ms, 42);
        assert_eq!(frame.payload, b"vp9");
    }

    #[test]
    fn read_frame_rejects_oversized_envelope_before_allocating_body() {
        let (mut writer, mut reader) = UnixStream::pair().expect("socket pair");
        writer
            .write_all(&(16_u32 * 1024 * 1024 + 1).to_be_bytes())
            .expect("write length");

        let error = read_frame(&mut reader).expect_err("oversized frame must fail");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(error.to_string(), "media frame exceeds size limit");
    }

    #[test]
    fn media_frame_debug_shape_remains_stable_for_protocol_receipts() {
        let frame = MediaFrame {
            kind: 0x01,
            flags: 0x01,
            pts_ms: 7,
            payload: vec![1, 2, 3],
        };
        assert_eq!(frame.payload.len(), 3);
        assert_eq!(
            format!("{frame:?}"),
            "MediaFrame { kind: 1, flags: 1, pts_ms: 7, payload: [1, 2, 3] }"
        );
    }

    #[test]
    #[cfg(not(feature = "media-gst"))]
    fn viewer_capability_serializes_stable_status_and_install_hint() {
        let value =
            serde_json::to_value(super::MediaViewer::capability()).expect("serialize capability");
        assert_eq!(value["status"], "built_without_gstreamer");
        assert_eq!(value["featureEnabled"], false);
        assert_eq!(
            value["installHint"],
            "Install the packaged Linux build with GStreamer support, or rebuild with --features media-gst."
        );
    }

    #[test]
    #[cfg(not(feature = "media-gst"))]
    fn viewer_capability_is_explicitly_stubbed_without_gstreamer() {
        let capability = super::MediaViewer::capability();
        assert!(!capability.available);
        assert_eq!(capability.renderer, "stub");
        assert!(!capability.feature_enabled);
        assert_eq!(capability.status, "built_without_gstreamer");
        assert_eq!(
            capability.reason.as_deref(),
            Some("linux_media_viewer_built_without_gstreamer")
        );
        assert_eq!(
            capability.install_hint,
            Some("Install the packaged Linux build with GStreamer support, or rebuild with --features media-gst.")
        );
    }

    #[test]
    #[cfg(feature = "media-gst")]
    fn viewer_restarts_decoder_after_decode_error() {
        let viewer = super::MediaViewer::new();
        {
            let mut inner = viewer.inner.lock().expect("viewer lock");
            inner.open = true;
            inner.decoder = Some(
                openburnbar_media::DecodePipeline::new(
                    "vp9",
                    openburnbar_media::DecodeSinkMode::Fake,
                )
                .expect("fake decoder"),
            );
        }

        // An empty keyframe is a deterministic decoder error that does not
        // depend on a particular VP9 plugin's error text. The viewer should
        // retain the pipeline after the one-shot restart and wait for the
        // next keyframe instead of going permanently black.
        viewer.render_frame(&MediaFrame {
            kind: 0x01,
            flags: 0x01,
            pts_ms: 0,
            payload: Vec::new(),
        });

        let inner = viewer.inner.lock().expect("viewer lock");
        assert!(inner.decoder.is_some(), "decoder was torn down too early");
        assert!(
            inner.awaiting_keyframe,
            "restart must re-arm keyframe gating"
        );
    }
}
