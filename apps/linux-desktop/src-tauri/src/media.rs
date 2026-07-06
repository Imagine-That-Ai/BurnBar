#[cfg(feature = "media-gst")]
use std::ffi::c_void;
#[cfg(feature = "media-gst")]
use std::io::Write;
use std::io::{ErrorKind, Read};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const MEDIA_SOCKET_NAME: &str = "openburnbar-media.sock";
const FRAME_HEADER_BYTES: usize = 10;
#[cfg(feature = "media-gst")]
const VIDEO_NAL_KIND: u8 = 0x01;
const DEFAULT_CAPTURE_BITRATE_BPS: u32 = 1_500_000;
const DEFAULT_CAPTURE_CODEC: CaptureCodec = CaptureCodec::Vp9;
#[cfg(feature = "media-gst")]
const MAX_CAPTURE_FRAME_BYTES: usize = (256 * 1024) - 18;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureCodec {
    Vp9,
    Av1,
}

impl CaptureCodec {
    fn as_wire_value(self) -> &'static str {
        match self {
            Self::Vp9 => "vp9",
            Self::Av1 => "av1",
        }
    }

    #[cfg(feature = "media-gst")]
    fn as_media_crate_value(self) -> openburnbar_media::CaptureCodec {
        match self {
            Self::Vp9 => openburnbar_media::CaptureCodec::Vp9,
            Self::Av1 => openburnbar_media::CaptureCodec::Av1,
        }
    }
}

impl std::str::FromStr for CaptureCodec {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "" | "vp9" => Ok(Self::Vp9),
            "av1" => Ok(Self::Av1),
            other => Err(format!("unsupported Linux Mercury capture codec: {other}")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptureSource {
    PipeWire { fd: i32, node_id: u32 },
    Test { num_buffers: u32 },
}

impl CaptureSource {
    fn label(&self) -> String {
        match self {
            Self::PipeWire { node_id, .. } => format!("pipewire:{node_id}"),
            Self::Test { num_buffers } => format!("test-video:{num_buffers}"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct CaptureStartOptions {
    pub session_id: String,
    pub source: CaptureSource,
    pub target_bitrate_bps: u32,
    pub codec: CaptureCodec,
}

#[derive(Debug, Clone)]
pub struct CaptureStatus {
    pub active: bool,
    pub session_id: Option<String>,
    pub source: Option<String>,
    pub codec: Option<String>,
    pub target_bitrate_bps: Option<u32>,
    pub socket_connected: bool,
}

#[derive(Debug)]
struct OutboundCaptureHandle {
    session_id: String,
    source: String,
    codec: CaptureCodec,
    target_bitrate_bps: u32,
    stop_tx: mpsc::Sender<()>,
}

#[derive(Default)]
struct OutboundCaptureState {
    writer: Option<Arc<Mutex<UnixStream>>>,
    active: Option<OutboundCaptureHandle>,
    last_source_error_session: Option<String>,
}

static OUTBOUND_CAPTURE: OnceLock<Mutex<OutboundCaptureState>> = OnceLock::new();

fn outbound_capture_state() -> &'static Mutex<OutboundCaptureState> {
    OUTBOUND_CAPTURE.get_or_init(|| Mutex::new(OutboundCaptureState::default()))
}

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
            match stream.try_clone() {
                Ok(writer) => set_capture_writer(Some(Arc::new(Mutex::new(writer)))),
                Err(error) => {
                    let _ = app.emit(
                        "media-capture-unavailable",
                        serde_json::json!({
                            "reason": format!("failed to clone media socket writer: {error}")
                        }),
                    );
                    set_capture_writer(None);
                }
            }
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
                        stop_outbound_capture_internal("media-socket-eof");
                        set_capture_writer(None);
                        viewer.close_window();
                        eprintln!("openburnbar media socket closed: {}", path.display());
                        break;
                    }
                    Err(e) => {
                        stop_outbound_capture_internal("media-socket-read-failed");
                        set_capture_writer(None);
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

pub fn sync_capture_with_session(app: &AppHandle, state: &serde_json::Value) {
    let session = state
        .get("session")
        .and_then(|value| value.as_object())
        .map(|_| &state["session"])
        .unwrap_or(state);
    let phase = string_field(session, &["phase", "state", "status"]);
    let kind = string_field(session, &["kind", "type"]);
    let is_streaming = phase
        .as_deref()
        .map(|value| {
            value.eq_ignore_ascii_case("streaming") || value.eq_ignore_ascii_case("active")
        })
        .unwrap_or(false);
    let is_mirror = kind
        .as_deref()
        .map(|value| {
            value.eq_ignore_ascii_case("mirror") || value.eq_ignore_ascii_case("screen-share")
        })
        .unwrap_or(false);

    if is_streaming && is_mirror {
        let session_id = string_field(session, &["sessionId", "sessionID", "session_id"])
            .or_else(|| string_field(session, &["requestId", "requestID", "request_id"]))
            .unwrap_or_else(|| "linux-mercury-screen-share".to_string());
        match capture_source_from_environment() {
            Ok(source) => {
                let codec = capture_codec_from_environment().unwrap_or(DEFAULT_CAPTURE_CODEC);
                let target_bitrate_bps = std::env::var("OPENBURNBAR_MEDIA_CAPTURE_BITRATE_BPS")
                    .ok()
                    .and_then(|value| value.parse::<u32>().ok())
                    .unwrap_or(DEFAULT_CAPTURE_BITRATE_BPS);
                if let Err(error) = start_outbound_capture(
                    app.clone(),
                    CaptureStartOptions {
                        session_id: session_id.clone(),
                        source,
                        target_bitrate_bps,
                        codec,
                    },
                ) {
                    emit_source_error_once(app, &session_id, &error);
                }
            }
            Err(error) => {
                emit_source_error_once(app, &session_id, &error);
            }
        }
    } else {
        stop_outbound_capture_internal("session-not-streaming");
    }
}

pub fn start_pipewire_capture(
    app: AppHandle,
    session_id: String,
    pw_fd: i32,
    pw_node_id: u32,
    target_bitrate_bps: Option<u32>,
    codec: Option<String>,
) -> Result<CaptureStatus, String> {
    let codec = codec
        .as_deref()
        .unwrap_or(DEFAULT_CAPTURE_CODEC.as_wire_value())
        .parse::<CaptureCodec>()?;
    start_outbound_capture(
        app,
        CaptureStartOptions {
            session_id,
            source: CaptureSource::PipeWire {
                fd: pw_fd,
                node_id: pw_node_id,
            },
            target_bitrate_bps: target_bitrate_bps.unwrap_or(DEFAULT_CAPTURE_BITRATE_BPS),
            codec,
        },
    )
}

pub fn start_test_capture(
    app: AppHandle,
    session_id: String,
    num_buffers: Option<u32>,
    target_bitrate_bps: Option<u32>,
    codec: Option<String>,
) -> Result<CaptureStatus, String> {
    let codec = codec
        .as_deref()
        .unwrap_or(DEFAULT_CAPTURE_CODEC.as_wire_value())
        .parse::<CaptureCodec>()?;
    start_outbound_capture(
        app,
        CaptureStartOptions {
            session_id,
            source: CaptureSource::Test {
                num_buffers: num_buffers.unwrap_or(300),
            },
            target_bitrate_bps: target_bitrate_bps.unwrap_or(DEFAULT_CAPTURE_BITRATE_BPS),
            codec,
        },
    )
}

pub fn stop_outbound_capture(reason: &str) -> CaptureStatus {
    stop_outbound_capture_internal(reason);
    capture_status()
}

pub fn capture_status() -> CaptureStatus {
    let state = outbound_capture_state().lock();
    match state {
        Ok(state) => capture_status_from_state(&state),
        Err(_) => inactive_capture_status(),
    }
}

fn capture_status_from_state(state: &OutboundCaptureState) -> CaptureStatus {
    CaptureStatus {
        active: state.active.is_some(),
        session_id: state
            .active
            .as_ref()
            .map(|active| active.session_id.clone()),
        source: state.active.as_ref().map(|active| active.source.clone()),
        codec: state
            .active
            .as_ref()
            .map(|active| active.codec.as_wire_value().to_string()),
        target_bitrate_bps: state
            .active
            .as_ref()
            .map(|active| active.target_bitrate_bps),
        socket_connected: state.writer.is_some(),
    }
}

fn inactive_capture_status() -> CaptureStatus {
    CaptureStatus {
        active: false,
        session_id: None,
        source: None,
        codec: None,
        target_bitrate_bps: None,
        socket_connected: false,
    }
}

fn start_outbound_capture(
    app: AppHandle,
    options: CaptureStartOptions,
) -> Result<CaptureStatus, String> {
    let writer = {
        let mut state = outbound_capture_state()
            .lock()
            .map_err(|_| "Linux Mercury capture state lock poisoned".to_string())?;
        if state
            .active
            .as_ref()
            .map(|active| active.session_id == options.session_id)
            .unwrap_or(false)
        {
            return Ok(capture_status_from_state(&state));
        }
        if let Some(active) = state.active.take() {
            let _ = active.stop_tx.send(());
        }
        state
            .writer
            .clone()
            .ok_or_else(|| "Linux Mercury media socket is not connected.".to_string())?
    };

    let source_label = options.source.label();
    let (stop_tx, stop_rx) = mpsc::channel();
    let (ready_tx, ready_rx) = mpsc::channel();
    let thread_options = options.clone();
    let thread_app = app.clone();
    thread::Builder::new()
        .name("openburnbar-media-capture-outbound".to_string())
        .spawn(move || {
            run_capture_thread(thread_app, writer, thread_options, stop_rx, ready_tx);
        })
        .map_err(|error| error.to_string())?;

    match ready_rx.recv_timeout(Duration::from_secs(10)) {
        Ok(Ok(())) => {
            let mut state = outbound_capture_state()
                .lock()
                .map_err(|_| "Linux Mercury capture state lock poisoned".to_string())?;
            state.last_source_error_session = None;
            state.active = Some(OutboundCaptureHandle {
                session_id: options.session_id.clone(),
                source: source_label,
                codec: options.codec,
                target_bitrate_bps: options.target_bitrate_bps,
                stop_tx,
            });
            Ok(capture_status_from_state(&state))
        }
        Ok(Err(error)) => Err(error),
        Err(_) => Err("Timed out while starting Linux Mercury capture.".to_string()),
    }
}

fn run_capture_thread(
    app: AppHandle,
    _writer: Arc<Mutex<UnixStream>>,
    options: CaptureStartOptions,
    stop_rx: mpsc::Receiver<()>,
    ready_tx: mpsc::Sender<Result<(), String>>,
) {
    #[cfg(feature = "media-gst")]
    {
        let callback_state = Arc::new(Mutex::new(CaptureCallbackState {
            writer: _writer,
            frame_count: 0,
            dropped_frame_count: 0,
        }));
        let user_data = Arc::into_raw(callback_state.clone()) as *mut c_void;
        let pipeline = match options.source {
            CaptureSource::PipeWire { fd, node_id } => {
                openburnbar_media::CapturePipeline::start_pipewire_video(
                    fd,
                    node_id,
                    options.target_bitrate_bps,
                    options.codec.as_media_crate_value(),
                    on_capture_frame,
                    user_data,
                )
            }
            CaptureSource::Test { num_buffers } => {
                openburnbar_media::CapturePipeline::start_test_video(
                    num_buffers,
                    options.target_bitrate_bps,
                    options.codec.as_media_crate_value(),
                    on_capture_frame,
                    user_data,
                )
            }
        };

        let pipeline = match pipeline {
            Ok(pipeline) => pipeline,
            Err(error) => {
                unsafe {
                    drop(Arc::from_raw(
                        user_data as *const Mutex<CaptureCallbackState>,
                    ));
                }
                let detail = error.to_string();
                let _ = ready_tx.send(Err(detail.clone()));
                let _ = app.emit(
                    "media-capture-stopped",
                    serde_json::json!({
                        "sessionId": options.session_id,
                        "reason": detail
                    }),
                );
                return;
            }
        };

        let _ = ready_tx.send(Ok(()));
        let _ = app.emit(
            "media-capture-started",
            serde_json::json!({
                "sessionId": options.session_id,
                "source": options.source.label(),
                "codec": options.codec.as_wire_value(),
                "targetBitrateBps": options.target_bitrate_bps
            }),
        );
        let _ = stop_rx.recv();
        let _ = pipeline.stop();
        let snapshot = callback_state.lock().ok().map(|state| {
            serde_json::json!({
                "frameCount": state.frame_count,
                "droppedFrameCount": state.dropped_frame_count
            })
        });
        unsafe {
            drop(Arc::from_raw(
                user_data as *const Mutex<CaptureCallbackState>,
            ));
        }
        let _ = app.emit(
            "media-capture-stopped",
            serde_json::json!({
                "sessionId": options.session_id,
                "reason": "stopped",
                "stats": snapshot
            }),
        );
    }

    #[cfg(not(feature = "media-gst"))]
    {
        let _ = stop_rx;
        let _ = ready_tx.send(Err(
            "openburnbar-linux-desktop was built without the media-gst feature".to_string(),
        ));
        let _ = app.emit(
            "media-capture-unavailable",
            serde_json::json!({
                "sessionId": options.session_id,
                "reason": "media-gst feature disabled"
            }),
        );
    }
}

#[cfg(feature = "media-gst")]
struct CaptureCallbackState {
    writer: Arc<Mutex<UnixStream>>,
    frame_count: u64,
    dropped_frame_count: u64,
}

#[cfg(feature = "media-gst")]
extern "C" fn on_capture_frame(
    payload: *const u8,
    len: usize,
    pts_ms: u64,
    flags: u8,
    user_data: *mut c_void,
) {
    if payload.is_null() || user_data.is_null() || len == 0 || len > MAX_CAPTURE_FRAME_BYTES {
        return;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload, len) };
    let state = unsafe { &*(user_data as *const Mutex<CaptureCallbackState>) };
    if let Ok(mut state) = state.lock() {
        let result = write_shell_frame(&mut state.writer, VIDEO_NAL_KIND, flags, pts_ms, bytes);
        if result.is_ok() {
            state.frame_count += 1;
        } else {
            state.dropped_frame_count += 1;
        }
    }
}

#[cfg(feature = "media-gst")]
fn write_shell_frame(
    writer: &mut Arc<Mutex<UnixStream>>,
    kind: u8,
    flags: u8,
    pts_ms: u64,
    payload: &[u8],
) -> std::io::Result<()> {
    let body_length = 1 + 1 + 8 + payload.len();
    let mut data = Vec::with_capacity(4 + body_length);
    data.extend_from_slice(&(body_length as u32).to_be_bytes());
    data.push(kind);
    data.push(flags);
    data.extend_from_slice(&pts_ms.to_be_bytes());
    data.extend_from_slice(payload);
    let mut stream = writer
        .lock()
        .map_err(|_| std::io::Error::new(ErrorKind::BrokenPipe, "media writer lock poisoned"))?;
    stream.write_all(&data)
}

fn set_capture_writer(writer: Option<Arc<Mutex<UnixStream>>>) {
    if let Ok(mut state) = outbound_capture_state().lock() {
        if writer.is_none() {
            if let Some(active) = state.active.take() {
                let _ = active.stop_tx.send(());
            }
        }
        state.writer = writer;
    }
}

fn stop_outbound_capture_internal(_reason: &str) {
    if let Ok(mut state) = outbound_capture_state().lock() {
        if let Some(active) = state.active.take() {
            let _ = active.stop_tx.send(());
        }
    }
}

fn capture_source_from_environment() -> Result<CaptureSource, String> {
    if std::env::var("OPENBURNBAR_MEDIA_CAPTURE_TEST")
        .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        let num_buffers = std::env::var("OPENBURNBAR_MEDIA_CAPTURE_TEST_BUFFERS")
            .ok()
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(300);
        return Ok(CaptureSource::Test { num_buffers });
    }

    let fd = std::env::var("OPENBURNBAR_MEDIA_PIPEWIRE_FD")
        .map_err(|_| "OPENBURNBAR_MEDIA_PIPEWIRE_FD is not set".to_string())?
        .parse::<i32>()
        .map_err(|error| format!("OPENBURNBAR_MEDIA_PIPEWIRE_FD is invalid: {error}"))?;
    let node_id = std::env::var("OPENBURNBAR_MEDIA_PIPEWIRE_NODE_ID")
        .map_err(|_| "OPENBURNBAR_MEDIA_PIPEWIRE_NODE_ID is not set".to_string())?
        .parse::<u32>()
        .map_err(|error| format!("OPENBURNBAR_MEDIA_PIPEWIRE_NODE_ID is invalid: {error}"))?;
    Ok(CaptureSource::PipeWire { fd, node_id })
}

fn capture_codec_from_environment() -> Result<CaptureCodec, String> {
    std::env::var("OPENBURNBAR_MEDIA_CAPTURE_CODEC")
        .unwrap_or_else(|_| DEFAULT_CAPTURE_CODEC.as_wire_value().to_string())
        .parse::<CaptureCodec>()
}

fn emit_source_error_once(app: &AppHandle, session_id: &str, error: &str) {
    if let Ok(mut state) = outbound_capture_state().lock() {
        if state
            .last_source_error_session
            .as_deref()
            .map(|last| last == session_id)
            .unwrap_or(false)
        {
            return;
        }
        state.last_source_error_session = Some(session_id.to_string());
    }
    let _ = app.emit(
        "media-capture-unavailable",
        serde_json::json!({
            "sessionId": session_id,
            "reason": error
        }),
    );
}

fn string_field(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(|field| field.as_str()))
        .map(str::to_string)
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
