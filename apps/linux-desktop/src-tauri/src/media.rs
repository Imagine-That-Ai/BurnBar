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

#[derive(Default)]
struct MediaViewerInner {
    received_frames: u64,
    open: bool,
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
        inner.open = true;
        let _ = app.emit(
            "media-viewer-ready",
            serde_json::json!({
                "source": if cfg!(feature = "media-gst") { "media-gst" } else { "stub" }
            }),
        );
        #[cfg(feature = "media-gst")]
        gst_viewer::ensure_window();
        #[cfg(not(feature = "media-gst"))]
        eprintln!("openburnbar media viewer stub: native GTK viewer window seam opened");
    }

    pub fn close_window(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.open = false;
        }
        #[cfg(feature = "media-gst")]
        gst_viewer::close_window();
    }

    pub fn render_frame(&self, frame: &MediaFrame) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.received_frames += 1;
        }
        #[cfg(feature = "media-gst")]
        gst_viewer::render_frame(frame);
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
                    None => eprintln!("openburnbar media socket unavailable: XDG_RUNTIME_DIR is unset"),
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
            eprintln!("openburnbar media socket not connected at {}: {e}", path.display());
        }
    }
}

fn read_frame(stream: &mut UnixStream) -> std::io::Result<MediaFrame> {
    let mut prefix = [0_u8; 4];
    stream.read_exact(&mut prefix)?;
    let len = u32::from_be_bytes(prefix) as usize;
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

#[cfg(feature = "media-gst")]
mod gst_viewer {
    use super::MediaFrame;

    pub fn ensure_window() {
        let _ = std::any::type_name::<openburnbar_media::MediaFrame>();
    }

    pub fn close_window() {}

    pub fn render_frame(_frame: &MediaFrame) {
        let _ = std::any::type_name::<openburnbar_media::MediaFrame>();
    }
}
