//! Native Linux playback for inbound Mercury audio frames.
//!
//! The daemon sends one Opus packet per `MediaFrame.Kind.audioOpus` frame over
//! the local media socket. This module owns the Linux-native decode and output
//! pipeline so the authenticated daemon route never has to know about
//! GStreamer details.
//! The native sink is selected by GStreamer (`autoaudiosink`), which keeps the
//! implementation aligned with PipeWire/PulseAudio/ALSA desktops while still
//! allowing deterministic fake-sink tests in headless CI.

#[cfg(feature = "gstreamer")]
use std::sync::atomic::{AtomicUsize, Ordering};
#[cfg(feature = "gstreamer")]
use std::sync::{Arc, Mutex};

use crate::{DecodeSinkMode, MediaError, Result};

#[cfg(feature = "gstreamer")]
use gst::prelude::*;

/// Maximum encoded Opus packet accepted by the playback boundary.
///
/// Opus packets used by Mercury are normally well below 4 KiB.  The larger
/// bound preserves room for future multichannel packets without allowing a
/// malformed socket peer to force an unbounded GStreamer allocation.
pub const MAX_OPUS_PACKET_BYTES: usize = 64 * 1024;

#[derive(Debug, Default)]
#[cfg(feature = "gstreamer")]
struct PlaybackState {
    eos_sent: bool,
    eos_complete: bool,
}

/// A GStreamer Opus decoder connected to either the native Linux audio device
/// or a deterministic fake sink.
#[cfg(feature = "gstreamer")]
pub struct AudioPlaybackPipeline {
    pipeline: gst::Pipeline,
    appsrc: gst_app::AppSrc,
    fake_sink_buffers: Arc<AtomicUsize>,
    state: Mutex<PlaybackState>,
}

#[cfg(feature = "gstreamer")]
impl AudioPlaybackPipeline {
    /// Create a playback pipeline for 48 kHz mono Opus packets.
    ///
    /// `Auto` uses GStreamer's native `autoaudiosink`, which selects the
    /// desktop's configured PipeWire/PulseAudio/ALSA output. `Fake` is used by
    /// deterministic tests and never opens an audio device.
    pub fn new(sink_mode: DecodeSinkMode) -> Result<Self> {
        crate::gst_runtime::ensure()?;

        let (sink, render_queue) = match sink_mode {
            DecodeSinkMode::Auto => (
                "autoaudiosink name=sink sync=false",
                "queue max-size-buffers=8 max-size-bytes=0 max-size-time=160000000 leaky=downstream ! ",
            ),
            DecodeSinkMode::Fake => (
                "fakesink name=sink sync=false signal-handoffs=true",
                "",
            ),
        };
        // The sender emits complete Opus packets. `alignment=au` prevents
        // GStreamer from waiting for an Ogg/WebM container and the explicit
        // mono/48 kHz caps match the Linux capture adapter and macOS encoder.
        let description = format!(
            "appsrc name=src caps=audio/x-opus,rate=(int)48000,channels=(int)1,channel-mapping-family=(int)0,stream-format=(string)packet,alignment=(string)au format=time is-live=true do-timestamp=false ! opusdec ! audioconvert ! audioresample ! {render_queue}{sink}"
        );
        let element = gst::parse::launch(&description)
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        let pipeline = element
            .downcast::<gst::Pipeline>()
            .map_err(|_| MediaError::pipeline("audio playback graph is not a pipeline"))?;
        let appsrc = pipeline
            .by_name("src")
            .ok_or_else(|| MediaError::pipeline("audio playback pipeline missing appsrc"))?
            .downcast::<gst_app::AppSrc>()
            .map_err(|_| MediaError::pipeline("audio playback src is not an appsrc"))?;

        // Never let a stalled desktop audio device back-pressure the socket
        // reader indefinitely. The leaky render queue above handles decoded
        // PCM; this appsrc bound handles encoded ingress.
        appsrc.set_property("block", false);
        appsrc.set_property("max-bytes", 256_u64 * 1024);

        let fake_sink_buffers = Arc::new(AtomicUsize::new(0));
        if sink_mode == DecodeSinkMode::Fake {
            let sink_element = pipeline
                .by_name("sink")
                .ok_or_else(|| MediaError::pipeline("audio playback pipeline missing fake sink"))?;
            let counter = fake_sink_buffers.clone();
            sink_element.connect("handoff", false, move |_| {
                counter.fetch_add(1, Ordering::SeqCst);
                None
            });
        }

        pipeline
            .set_state(gst::State::Playing)
            .map_err(|error| MediaError::state_change(format!("{error:?}")))?;
        Ok(Self {
            pipeline,
            appsrc,
            fake_sink_buffers,
            state: Mutex::new(PlaybackState::default()),
        })
    }

    /// Push one complete Opus packet into the decoder.
    pub fn push_packet(&self, payload: &[u8], pts_ms: u64) -> Result<()> {
        if payload.is_empty() {
            return Err(MediaError::invalid_argument(
                "encoded Opus packet must not be empty",
            ));
        }
        if payload.len() > MAX_OPUS_PACKET_BYTES {
            return Err(MediaError::invalid_argument(format!(
                "encoded Opus packet exceeds {MAX_OPUS_PACKET_BYTES} byte limit"
            )));
        }
        self.check_bus()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| MediaError::state_change("audio playback state lock poisoned"))?;
        if state.eos_sent || state.eos_complete {
            return Err(MediaError::state_change(
                "audio playback reached EOS; call restart before pushing packets",
            ));
        }
        let mut buffer = gst::Buffer::with_size(payload.len())
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        {
            let buffer_mut = buffer
                .get_mut()
                .ok_or_else(|| MediaError::pipeline("new audio buffer was not mutable"))?;
            let mut map = buffer_mut
                .map_writable()
                .map_err(|error| MediaError::pipeline(error.to_string()))?;
            map.as_mut_slice().copy_from_slice(payload);
        }
        buffer_mut.set_pts(gst::ClockTime::from_mseconds(pts_ms));
        // A complete packet is one access unit. This flag is meaningful
        // to downstream queues and keeps packet boundaries explicit.
        buffer_mut.set_duration(gst::ClockTime::from_mseconds(20));
        self.appsrc
            .push_buffer(buffer)
            .map(|_| ())
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        drop(state);
        self.check_bus()
    }

    /// Drain queued packets and mark the current stream as ended.
    pub fn flush(&self) -> Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| MediaError::state_change("audio playback state lock poisoned"))?;
        if state.eos_complete {
            return Ok(());
        }
        if !state.eos_sent {
            self.appsrc
                .end_of_stream()
                .map_err(|error| MediaError::pipeline(error.to_string()))?;
            state.eos_sent = true;
        }
        drop(state);
        self.wait_for_eos()
    }

    /// Reset the decoder after EOS or a disconnected call.
    pub fn restart(&self) -> Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| MediaError::state_change("audio playback state lock poisoned"))?;
        self.pipeline
            .set_state(gst::State::Null)
            .map_err(|error| MediaError::state_change(format!("{error:?}")))?;
        self.pipeline
            .set_state(gst::State::Playing)
            .map_err(|error| MediaError::state_change(format!("{error:?}")))?;
        state.eos_sent = false;
        state.eos_complete = false;
        drop(state);
        self.check_bus()
    }

    pub fn stop(&self) -> Result<()> {
        self.pipeline
            .set_state(gst::State::Null)
            .map_err(|error| MediaError::state_change(format!("{error:?}")))?;
        Ok(())
    }

    pub fn fake_sink_buffer_count(&self) -> usize {
        self.fake_sink_buffers.load(Ordering::SeqCst)
    }

    fn wait_for_eos(&self) -> Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| MediaError::state_change("audio playback state lock poisoned"))?;
        if state.eos_complete {
            return Ok(());
        }
        let bus = self
            .pipeline
            .bus()
            .ok_or_else(|| MediaError::pipeline("audio playback pipeline missing bus"))?;
        loop {
            if let Some(message) = bus.timed_pop_filtered(
                gst::ClockTime::from_seconds(10),
                &[gst::MessageType::Eos, gst::MessageType::Error],
            ) {
                if let Some(detail) = crate::gst_runtime::bus_error_detail(&message) {
                    return Err(MediaError::bus(detail));
                }
                if matches!(message.view(), gst::MessageView::Eos(..)) {
                    state.eos_complete = true;
                    return Ok(());
                }
            } else {
                return Err(MediaError::bus("timed out waiting for audio playback EOS"));
            }
        }
    }

    fn check_bus(&self) -> Result<()> {
        let bus = self
            .pipeline
            .bus()
            .ok_or_else(|| MediaError::pipeline("audio playback pipeline missing bus"))?;
        while let Some(message) =
            bus.timed_pop_filtered(gst::ClockTime::ZERO, &[gst::MessageType::Error])
        {
            if let Some(detail) = crate::gst_runtime::bus_error_detail(&message) {
                return Err(MediaError::bus(detail));
            }
        }
        Ok(())
    }
}

/// C ABI for the Swift Linux daemon's optional playback adapter. The shell
/// and daemon use the same GStreamer implementation, but the daemon owns
/// inbound Mercury route admission and therefore must be able to fail closed
/// before forwarding a decoded Opus packet to an unavailable sink.
#[cfg(feature = "gstreamer")]
#[no_mangle]
pub extern "C" fn media_audio_playback_start(
    sample_rate: u32,
    channels: u8,
) -> *mut std::ffi::c_void {
    if sample_rate != 48_000 || channels != 1 {
        return std::ptr::null_mut();
    }
    match AudioPlaybackPipeline::new(DecodeSinkMode::Auto) {
        Ok(pipeline) => Box::into_raw(Box::new(pipeline)).cast(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[cfg(feature = "gstreamer")]
#[no_mangle]
/// # Safety
///
/// `pipeline` must be a live pointer returned by
/// [`media_audio_playback_start`], and `payload` must reference `len` readable
/// bytes for the duration of this call.
pub unsafe extern "C" fn media_audio_playback_push(
    pipeline: *mut std::ffi::c_void,
    payload: *const u8,
    len: usize,
    pts_ms: u64,
) -> i32 {
    if pipeline.is_null() || payload.is_null() || len == 0 {
        return -1;
    }
    // SAFETY: callers receive this opaque pointer only from
    // `media_audio_playback_start` and must stop it exactly once. The payload
    // is borrowed for the duration of this synchronous copy into GStreamer.
    let pipeline = unsafe { &*(pipeline.cast::<AudioPlaybackPipeline>()) };
    let payload = unsafe { std::slice::from_raw_parts(payload, len) };
    pipeline.push_packet(payload, pts_ms).map_or(-1, |_| 0)
}

#[cfg(feature = "gstreamer")]
#[no_mangle]
/// # Safety
///
/// `pipeline` must be null or a live pointer returned by
/// [`media_audio_playback_start`] that has not already been stopped.
pub unsafe extern "C" fn media_audio_playback_stop(pipeline: *mut std::ffi::c_void) {
    if pipeline.is_null() {
        return;
    }
    // SAFETY: ownership is returned exactly once by the matching start/stop
    // pair. Drop also transitions the GStreamer pipeline to NULL.
    let pipeline = unsafe { Box::from_raw(pipeline.cast::<AudioPlaybackPipeline>()) };
    let _ = pipeline.stop();
}

#[cfg(feature = "gstreamer")]
impl Drop for AudioPlaybackPipeline {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

#[cfg(not(feature = "gstreamer"))]
pub struct AudioPlaybackPipeline;

#[cfg(not(feature = "gstreamer"))]
impl AudioPlaybackPipeline {
    pub fn new(_sink_mode: DecodeSinkMode) -> Result<Self> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn push_packet(&self, _payload: &[u8], _pts_ms: u64) -> Result<()> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn flush(&self) -> Result<()> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn restart(&self) -> Result<()> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn stop(&self) -> Result<()> {
        Ok(())
    }

    pub fn fake_sink_buffer_count(&self) -> usize {
        0
    }
}

#[cfg(not(feature = "gstreamer"))]
#[no_mangle]
pub extern "C" fn media_audio_playback_start(
    _sample_rate: u32,
    _channels: u8,
) -> *mut std::ffi::c_void {
    std::ptr::null_mut()
}

#[cfg(not(feature = "gstreamer"))]
#[no_mangle]
/// # Safety
///
/// This fail-closed stub never dereferences its arguments.
pub unsafe extern "C" fn media_audio_playback_push(
    _pipeline: *mut std::ffi::c_void,
    _payload: *const u8,
    _len: usize,
    _pts_ms: u64,
) -> i32 {
    -1
}

#[cfg(not(feature = "gstreamer"))]
#[no_mangle]
/// # Safety
///
/// This fail-closed stub never dereferences its argument.
pub unsafe extern "C" fn media_audio_playback_stop(_pipeline: *mut std::ffi::c_void) {}
