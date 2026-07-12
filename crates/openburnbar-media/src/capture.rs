use std::ffi::c_void;

#[cfg(feature = "gstreamer")]
use crate::MEDIA_FRAME_FLAG_KEYFRAME;
use crate::{MediaError, Result};

#[cfg(feature = "gstreamer")]
use gst::prelude::*;

pub type CaptureFrameCallback =
    extern "C" fn(payload: *const u8, len: usize, pts_ms: u64, flags: u8, user_data: *mut c_void);
pub type CaptureStoppedCallback =
    extern "C" fn(user_data: *mut c_void, reason: *const u8, reason_len: usize);

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureCodec {
    Vp9 = 0,
    Av1 = 1,
}

impl CaptureCodec {
    pub fn from_u8(value: u8) -> Result<Self> {
        match value {
            0 => Ok(Self::Vp9),
            1 => Ok(Self::Av1),
            _ => Err(MediaError::invalid_argument(format!(
                "unknown capture codec {value}"
            ))),
        }
    }
}

#[cfg(feature = "gstreamer")]
pub struct CapturePipeline {
    pipeline: gst::Pipeline,
    stop_requested: std::sync::Arc<std::sync::atomic::AtomicBool>,
    bus_thread: Option<std::thread::JoinHandle<()>>,
}

#[cfg(feature = "gstreamer")]
impl CapturePipeline {
    pub fn start_pipewire_video(
        pw_fd: i32,
        pw_node_id: u32,
        target_bitrate_bps: u32,
        codec: CaptureCodec,
        on_frame: CaptureFrameCallback,
        on_stopped: Option<CaptureStoppedCallback>,
        user_data: *mut c_void,
    ) -> Result<Self> {
        let source = format!("pipewiresrc fd={pw_fd} path={pw_node_id}");
        Self::start_video_from_source(
            &source,
            target_bitrate_bps,
            codec,
            on_frame,
            on_stopped,
            user_data,
        )
    }

    pub fn start_test_video(
        num_buffers: u32,
        target_bitrate_bps: u32,
        codec: CaptureCodec,
        on_frame: CaptureFrameCallback,
        on_stopped: Option<CaptureStoppedCallback>,
        user_data: *mut c_void,
    ) -> Result<Self> {
        let source = format!(
            "videotestsrc num-buffers={num_buffers} is-live=false ! video/x-raw,width=320,height=240,framerate=30/1"
        );
        Self::start_video_from_source(
            &source,
            target_bitrate_bps,
            codec,
            on_frame,
            on_stopped,
            user_data,
        )
    }

    pub fn start_pipewire_audio(
        pw_fd: i32,
        pw_node_id: u32,
        on_frame: CaptureFrameCallback,
        on_stopped: Option<CaptureStoppedCallback>,
        user_data: *mut c_void,
    ) -> Result<Self> {
        let source = format!("pipewiresrc fd={pw_fd} path={pw_node_id}");
        Self::start_audio_from_source(&source, on_frame, on_stopped, user_data)
    }

    pub fn start_test_audio(
        num_buffers: u32,
        on_frame: CaptureFrameCallback,
        on_stopped: Option<CaptureStoppedCallback>,
        user_data: *mut c_void,
    ) -> Result<Self> {
        let source = format!(
            "audiotestsrc num-buffers={num_buffers} is-live=false ! audio/x-raw,rate=48000,channels=1"
        );
        Self::start_audio_from_source(&source, on_frame, on_stopped, user_data)
    }

    pub fn set_bitrate(&self, target_bitrate_bps: u32) -> Result<()> {
        if let Some(encoder) = self.pipeline.by_name("encoder") {
            if encoder.has_property("target-bitrate") {
                encoder.set_property("target-bitrate", target_bitrate_bps);
            } else if encoder.has_property("bitrate") {
                encoder.set_property("bitrate", target_bitrate_bps);
            } else {
                return Err(MediaError::pipeline(
                    "capture encoder does not expose a bitrate property",
                ));
            }
            Ok(())
        } else {
            Err(MediaError::pipeline("capture pipeline missing encoder"))
        }
    }

    pub fn stop(&mut self) -> Result<()> {
        self.stop_requested
            .store(true, std::sync::atomic::Ordering::SeqCst);
        self.pipeline
            .set_state(gst::State::Null)
            .map_err(|error| MediaError::state_change(format!("{error:?}")))?;
        if let Some(thread) = self.bus_thread.take() {
            let _ = thread.join();
        }
        Ok(())
    }

    fn start_video_from_source(
        source: &str,
        target_bitrate_bps: u32,
        codec: CaptureCodec,
        on_frame: CaptureFrameCallback,
        on_stopped: Option<CaptureStoppedCallback>,
        user_data: *mut c_void,
    ) -> Result<Self> {
        crate::gst_runtime::ensure()?;
        let encoder = match codec {
            CaptureCodec::Vp9 => format!(
                "vp9enc name=encoder deadline=1 end-usage=cbr keyframe-max-dist=60 target-bitrate={target_bitrate_bps}"
            ),
            CaptureCodec::Av1 => format!(
                "av1enc name=encoder usage-profile=realtime target-bitrate={target_bitrate_bps}"
            ),
        };
        let description = format!(
            "{source} ! videoconvert ! {encoder} ! appsink name=sink emit-signals=true sync=false max-buffers=8 drop=true"
        );
        Self::start_from_description(&description, on_frame, on_stopped, user_data)
    }

    fn start_audio_from_source(
        source: &str,
        on_frame: CaptureFrameCallback,
        on_stopped: Option<CaptureStoppedCallback>,
        user_data: *mut c_void,
    ) -> Result<Self> {
        crate::gst_runtime::ensure()?;
        let description = format!(
            "{source} ! audioconvert ! opusenc name=encoder bitrate=64000 ! appsink name=sink emit-signals=true sync=false max-buffers=8 drop=true"
        );
        Self::start_from_description(&description, on_frame, on_stopped, user_data)
    }

    fn start_from_description(
        description: &str,
        on_frame: CaptureFrameCallback,
        on_stopped: Option<CaptureStoppedCallback>,
        user_data: *mut c_void,
    ) -> Result<Self> {
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::sync::Arc;

        use gst::prelude::*;
        use gst_app::{AppSink, AppSinkCallbacks};

        let element = gst::parse::launch(description)
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        let pipeline = element
            .downcast::<gst::Pipeline>()
            .map_err(|_| MediaError::pipeline("capture graph is not a pipeline"))?;
        let appsink = pipeline
            .by_name("sink")
            .ok_or_else(|| MediaError::pipeline("capture pipeline missing appsink"))?
            .downcast::<AppSink>()
            .map_err(|_| MediaError::pipeline("capture sink is not an appsink"))?;

        let user_data = user_data as usize;
        let frame_index = Arc::new(AtomicU64::new(0));
        let callback_index = frame_index.clone();
        appsink.set_callbacks(
            AppSinkCallbacks::builder()
                .new_sample(move |sink| {
                    let sample = sink.pull_sample().map_err(|_| gst::FlowError::Error)?;
                    let buffer = sample.buffer().ok_or(gst::FlowError::Error)?;
                    let map = buffer.map_readable().map_err(|_| gst::FlowError::Error)?;
                    let index = callback_index.fetch_add(1, Ordering::SeqCst);
                    let pts_ms = buffer.pts().map(|pts| pts.mseconds()).unwrap_or(index * 33);
                    let mut flags = 0;
                    if index == 0 || !buffer.flags().contains(gst::BufferFlags::DELTA_UNIT) {
                        flags |= MEDIA_FRAME_FLAG_KEYFRAME;
                    }
                    on_frame(
                        map.as_slice().as_ptr(),
                        map.as_slice().len(),
                        pts_ms,
                        flags,
                        user_data as *mut c_void,
                    );
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );

        let stop_requested = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let bus_thread = if let Some(on_stopped) = on_stopped {
            let bus = pipeline
                .bus()
                .ok_or_else(|| MediaError::pipeline("capture pipeline missing bus"))?;
            let bus_stop_requested = stop_requested.clone();
            let stopped_user_data = user_data as usize;
            Some(
                std::thread::Builder::new()
                    .name("openburnbar-media-capture-bus".to_string())
                    .spawn(move || loop {
                        if bus_stop_requested.load(std::sync::atomic::Ordering::SeqCst) {
                            return;
                        }
                        let message = bus.timed_pop_filtered(
                            gst::ClockTime::from_mseconds(200),
                            &[gst::MessageType::Eos, gst::MessageType::Error],
                        );
                        let Some(message) = message else {
                            continue;
                        };
                        if bus_stop_requested.load(std::sync::atomic::Ordering::SeqCst) {
                            return;
                        }
                        let reason = match message.view() {
                            gst::MessageView::Error(error) => {
                                format!("capture_pipeline_error:{}", error.error())
                            }
                            gst::MessageView::Eos(_) => "capture_pipeline_eos".to_string(),
                            _ => "capture_pipeline_ended".to_string(),
                        };
                        on_stopped(
                            stopped_user_data as *mut c_void,
                            reason.as_ptr(),
                            reason.len(),
                        );
                        return;
                    })
                    .map_err(|error| MediaError::pipeline(error.to_string()))?,
            )
        } else {
            None
        };

        pipeline
            .set_state(gst::State::Playing)
            .map_err(|error| MediaError::state_change(format!("{error:?}")))?;
        Ok(Self {
            pipeline,
            stop_requested,
            bus_thread,
        })
    }
}

#[cfg(feature = "gstreamer")]
impl Drop for CapturePipeline {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[cfg(not(feature = "gstreamer"))]
pub struct CapturePipeline;

#[cfg(not(feature = "gstreamer"))]
impl CapturePipeline {
    pub fn start_pipewire_video(
        _pw_fd: i32,
        _pw_node_id: u32,
        _target_bitrate_bps: u32,
        _codec: CaptureCodec,
        _on_frame: CaptureFrameCallback,
        _on_stopped: Option<CaptureStoppedCallback>,
        _user_data: *mut c_void,
    ) -> Result<Self> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn start_test_video(
        _num_buffers: u32,
        _target_bitrate_bps: u32,
        _codec: CaptureCodec,
        _on_frame: CaptureFrameCallback,
        _on_stopped: Option<CaptureStoppedCallback>,
        _user_data: *mut c_void,
    ) -> Result<Self> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn start_pipewire_audio(
        _pw_fd: i32,
        _pw_node_id: u32,
        _on_frame: CaptureFrameCallback,
        _on_stopped: Option<CaptureStoppedCallback>,
        _user_data: *mut c_void,
    ) -> Result<Self> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn start_test_audio(
        _num_buffers: u32,
        _on_frame: CaptureFrameCallback,
        _on_stopped: Option<CaptureStoppedCallback>,
        _user_data: *mut c_void,
    ) -> Result<Self> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn set_bitrate(&self, _target_bitrate_bps: u32) -> Result<()> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn stop(&mut self) -> Result<()> {
        Ok(())
    }
}

#[no_mangle]
pub extern "C" fn media_capture_start(
    pw_fd: i32,
    pw_node_id: u32,
    target_bitrate_bps: u32,
    codec: u8,
    on_frame: Option<CaptureFrameCallback>,
    on_stopped: Option<CaptureStoppedCallback>,
    user_data: *mut c_void,
) -> *mut CapturePipeline {
    let Some(on_frame) = on_frame else {
        return std::ptr::null_mut();
    };
    let Ok(codec) = CaptureCodec::from_u8(codec) else {
        return std::ptr::null_mut();
    };
    match CapturePipeline::start_pipewire_video(
        pw_fd,
        pw_node_id,
        target_bitrate_bps,
        codec,
        on_frame,
        on_stopped,
        user_data,
    ) {
        Ok(pipeline) => Box::into_raw(Box::new(pipeline)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn media_capture_start_test(
    num_buffers: u32,
    target_bitrate_bps: u32,
    codec: u8,
    on_frame: Option<CaptureFrameCallback>,
    on_stopped: Option<CaptureStoppedCallback>,
    user_data: *mut c_void,
) -> *mut CapturePipeline {
    let Some(on_frame) = on_frame else {
        return std::ptr::null_mut();
    };
    let Ok(codec) = CaptureCodec::from_u8(codec) else {
        return std::ptr::null_mut();
    };
    match CapturePipeline::start_test_video(
        num_buffers,
        target_bitrate_bps,
        codec,
        on_frame,
        on_stopped,
        user_data,
    ) {
        Ok(pipeline) => Box::into_raw(Box::new(pipeline)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn media_audio_capture_start(
    pw_fd: i32,
    pw_node_id: u32,
    on_frame: Option<CaptureFrameCallback>,
    on_stopped: Option<CaptureStoppedCallback>,
    user_data: *mut c_void,
) -> *mut CapturePipeline {
    let Some(on_frame) = on_frame else {
        return std::ptr::null_mut();
    };
    match CapturePipeline::start_pipewire_audio(pw_fd, pw_node_id, on_frame, on_stopped, user_data)
    {
        Ok(pipeline) => Box::into_raw(Box::new(pipeline)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn media_capture_stop(pipeline: *mut CapturePipeline) {
    if pipeline.is_null() {
        return;
    }
    unsafe {
        let mut pipeline = Box::from_raw(pipeline);
        let _ = pipeline.stop();
    }
}

#[no_mangle]
pub extern "C" fn media_capture_set_bitrate(
    pipeline: *mut CapturePipeline,
    target_bitrate_bps: u32,
) {
    if pipeline.is_null() {
        return;
    }
    unsafe {
        let _ = (*pipeline).set_bitrate(target_bitrate_bps);
    }
}
