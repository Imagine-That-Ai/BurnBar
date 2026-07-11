#[cfg(feature = "gstreamer")]
use std::sync::atomic::{AtomicUsize, Ordering};
#[cfg(feature = "gstreamer")]
use std::sync::Arc;

#[cfg(feature = "gstreamer")]
use crate::MEDIA_FRAME_FLAG_KEYFRAME;
use crate::{MediaError, Result};

#[cfg(feature = "gstreamer")]
use gst::prelude::*;

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeSinkMode {
    Auto = 0,
    Fake = 1,
}

impl DecodeSinkMode {
    pub fn from_u8(value: u8) -> Result<Self> {
        match value {
            0 => Ok(Self::Auto),
            1 => Ok(Self::Fake),
            _ => Err(MediaError::invalid_argument(format!(
                "unknown decode sink mode {value}"
            ))),
        }
    }
}

#[cfg(feature = "gstreamer")]
pub struct DecodePipeline {
    pipeline: gst::Pipeline,
    appsrc: gst_app::AppSrc,
    fake_sink_buffers: Arc<AtomicUsize>,
}

#[cfg(feature = "gstreamer")]
impl DecodePipeline {
    pub fn new(codec: &str, sink_mode: DecodeSinkMode) -> Result<Self> {
        crate::gst_runtime::ensure()?;
        if codec != "vp9" {
            return Err(MediaError::invalid_argument(format!(
                "unsupported decode codec {codec}"
            )));
        }

        let sink = match sink_mode {
            DecodeSinkMode::Auto => "autovideosink name=sink sync=false",
            DecodeSinkMode::Fake => "fakesink name=sink sync=false signal-handoffs=true",
        };
        let description = format!(
            "appsrc name=src caps=video/x-vp9 format=time is-live=true do-timestamp=false ! vp9dec ! videoconvert ! {sink}"
        );
        let element = gst::parse::launch(&description)
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        let pipeline = element
            .downcast::<gst::Pipeline>()
            .map_err(|_| MediaError::pipeline("decode graph is not a pipeline"))?;
        let appsrc = pipeline
            .by_name("src")
            .ok_or_else(|| MediaError::pipeline("decode pipeline missing appsrc"))?
            .downcast::<gst_app::AppSrc>()
            .map_err(|_| MediaError::pipeline("decode src is not an appsrc"))?;

        let fake_sink_buffers = Arc::new(AtomicUsize::new(0));
        if sink_mode == DecodeSinkMode::Fake {
            if let Some(sink_element) = pipeline.by_name("sink") {
                let counter = fake_sink_buffers.clone();
                sink_element.connect("handoff", false, move |_| {
                    counter.fetch_add(1, Ordering::SeqCst);
                    None
                });
            }
        }

        pipeline
            .set_state(gst::State::Playing)
            .map_err(|error| MediaError::state_change(format!("{error:?}")))?;
        Ok(Self {
            pipeline,
            appsrc,
            fake_sink_buffers,
        })
    }

    pub fn push_frame(&self, payload: &[u8], pts_ms: u64, flags: u8) -> Result<()> {
        self.check_bus()?;
        let mut buffer = gst::Buffer::with_size(payload.len())
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        {
            let buffer_mut = buffer
                .get_mut()
                .ok_or_else(|| MediaError::pipeline("new decode buffer was not mutable"))?;
            {
                let mut map = buffer_mut
                    .map_writable()
                    .map_err(|error| MediaError::pipeline(error.to_string()))?;
                map.as_mut_slice().copy_from_slice(payload);
            }
            buffer_mut.set_pts(gst::ClockTime::from_mseconds(pts_ms));
            if flags & MEDIA_FRAME_FLAG_KEYFRAME == 0 {
                buffer_mut.set_flags(gst::BufferFlags::DELTA_UNIT);
            }
        }
        self.appsrc
            .push_buffer(buffer)
            .map(|_| ())
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        self.check_bus()
    }

    pub fn flush(&self) -> Result<()> {
        self.appsrc
            .end_of_stream()
            .map_err(|error| MediaError::pipeline(error.to_string()))?;
        self.wait_for_eos()
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

    pub fn wait_for_eos(&self) -> Result<()> {
        let bus = self
            .pipeline
            .bus()
            .ok_or_else(|| MediaError::pipeline("decode pipeline missing bus"))?;
        loop {
            if let Some(message) = bus.timed_pop_filtered(
                gst::ClockTime::from_seconds(10),
                &[gst::MessageType::Eos, gst::MessageType::Error],
            ) {
                if let Some(detail) = crate::gst_runtime::bus_error_detail(&message) {
                    return Err(MediaError::bus(detail));
                }
                if matches!(message.view(), gst::MessageView::Eos(..)) {
                    return Ok(());
                }
            } else {
                return Err(MediaError::bus("timed out waiting for decode EOS"));
            }
        }
    }

    fn check_bus(&self) -> Result<()> {
        let bus = self
            .pipeline
            .bus()
            .ok_or_else(|| MediaError::pipeline("decode pipeline missing bus"))?;
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

#[cfg(feature = "gstreamer")]
impl Drop for DecodePipeline {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

#[cfg(not(feature = "gstreamer"))]
pub struct DecodePipeline;

#[cfg(not(feature = "gstreamer"))]
impl DecodePipeline {
    pub fn new(_codec: &str, _sink_mode: DecodeSinkMode) -> Result<Self> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn push_frame(&self, _payload: &[u8], _pts_ms: u64, _flags: u8) -> Result<()> {
        Err(MediaError::unavailable(
            "openburnbar-media was built without the gstreamer feature",
        ))
    }

    pub fn flush(&self) -> Result<()> {
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
