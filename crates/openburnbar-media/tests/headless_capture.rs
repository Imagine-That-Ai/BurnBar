#![cfg(feature = "gstreamer")]

use std::ffi::c_void;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use openburnbar_media::{CaptureCodec, CapturePipeline, MEDIA_FRAME_FLAG_KEYFRAME};

#[derive(Default)]
struct CaptureState {
    frame_count: usize,
    last_pts: Option<u64>,
    first_keyframe: bool,
    monotonic_pts: bool,
}

#[test]
fn videotest_capture_delivers_monotonic_vp9_frames() {
    let state = Arc::new(Mutex::new(CaptureState {
        monotonic_pts: true,
        ..CaptureState::default()
    }));
    let user_data = Arc::into_raw(state.clone()) as *mut c_void;
    let pipeline =
        CapturePipeline::start_test_video(30, 600_000, CaptureCodec::Vp9, on_frame, user_data)
            .expect("capture pipeline");

    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if state.lock().expect("state").frame_count >= 30 {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    pipeline.stop().expect("capture stop");
    unsafe {
        drop(Arc::from_raw(user_data as *const Mutex<CaptureState>));
    }

    let state = state.lock().expect("state");
    assert!(state.frame_count >= 30, "got {} frames", state.frame_count);
    assert!(state.monotonic_pts, "pts should be monotonic");
    assert!(state.first_keyframe, "frame 0 should be flagged keyframe");
}

extern "C" fn on_frame(
    payload: *const u8,
    len: usize,
    pts_ms: u64,
    flags: u8,
    user_data: *mut c_void,
) {
    assert!(!payload.is_null());
    assert!(len > 0);
    let state = unsafe { &*(user_data as *const Mutex<CaptureState>) };
    let mut state = state.lock().expect("state");
    if state.frame_count == 0 {
        state.first_keyframe = flags & MEDIA_FRAME_FLAG_KEYFRAME != 0;
    }
    if let Some(last_pts) = state.last_pts {
        if pts_ms < last_pts {
            state.monotonic_pts = false;
        }
    }
    state.last_pts = Some(pts_ms);
    state.frame_count += 1;
}
