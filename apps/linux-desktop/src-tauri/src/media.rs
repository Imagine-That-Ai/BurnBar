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
            "reason": decoder_error,
        });
        #[cfg(not(feature = "media-gst"))]
        let ready_payload = serde_json::json!({
            "source": "stub",
            "available": false,
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
            let Some(decoder) = inner.decoder.as_ref() else {
                return;
            };
            if let Err(error) = decoder.push_frame(&frame.payload, frame.pts_ms, frame.flags) {
                eprintln!("openburnbar media viewer decode failed: {error}");
                let decoder = inner.decoder.take();
                drop(inner);
                if let Some(decoder) = decoder {
                    let _ = decoder.stop();
                }
                if let Ok(mut inner) = self.inner.lock() {
                    inner.awaiting_keyframe = true;
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
}
