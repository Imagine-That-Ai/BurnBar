#ifndef OPENBURNBAR_MEDIA_CAPTURE_H
#define OPENBURNBAR_MEDIA_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*OpenBurnBarMediaCaptureFrameCallback)(
    const uint8_t *payload,
    size_t len,
    uint64_t pts_ms,
    uint8_t flags,
    void *user_data
);

typedef void (*OpenBurnBarMediaCaptureStoppedCallback)(
    void *user_data,
    const char *reason,
    size_t reason_len
);

typedef struct OpenBurnBarMediaCapabilities {
    uint8_t backend_available;
    uint8_t vp9enc;
    uint8_t vp9dec;
    uint8_t av1enc;
    uint8_t av1dec;
    uint8_t opusenc;
    uint8_t opusdec;
    uint8_t pipewiresrc;
} OpenBurnBarMediaCapabilities;

/// Returns non-zero when the packaged backend has both an Opus decoder and a
/// constructible native Linux audio sink. This separate ABI preserves the
/// layout of the existing capture capability struct.
uint8_t media_audio_playback_probe(void);

/// Returns an opaque native GStreamer Opus playback pipeline for 48 kHz mono
/// packets, or NULL when the packaged media backend/output sink is unavailable.
void *media_audio_playback_start(uint32_t sample_rate, uint8_t channels);

/// Pushes one complete Opus packet. Returns 0 on success and a negative value
/// when the pipeline rejects the packet or has entered an error state.
int32_t media_audio_playback_push(
    void *pipeline,
    const uint8_t *payload,
    size_t len,
    uint64_t pts_ms
);

/// Stops and releases an opaque playback pipeline. NULL is accepted.
void media_audio_playback_stop(void *pipeline);

void *media_capture_start(
    int32_t pw_fd,
    uint32_t pw_node_id,
    uint32_t target_bitrate_bps,
    uint8_t codec,
    OpenBurnBarMediaCaptureFrameCallback on_frame,
    OpenBurnBarMediaCaptureStoppedCallback on_stopped,
    void *user_data
);

void *media_capture_start_test(
    uint32_t num_buffers,
    uint32_t target_bitrate_bps,
    uint8_t codec,
    OpenBurnBarMediaCaptureFrameCallback on_frame,
    OpenBurnBarMediaCaptureStoppedCallback on_stopped,
    void *user_data
);

void *media_audio_capture_start(
    int32_t pw_fd,
    uint32_t pw_node_id,
    OpenBurnBarMediaCaptureFrameCallback on_frame,
    OpenBurnBarMediaCaptureStoppedCallback on_stopped,
    void *user_data
);

// Deterministic audio pipeline used by native integration tests. Production
// callers must use media_audio_capture_start with a live portal PipeWire grant.
void *media_audio_capture_start_test(
    uint32_t num_buffers,
    OpenBurnBarMediaCaptureFrameCallback on_frame,
    OpenBurnBarMediaCaptureStoppedCallback on_stopped,
    void *user_data
);

void media_capture_stop(void *pipeline);

void media_capture_set_bitrate(
    void *pipeline,
    uint32_t target_bitrate_bps
);

OpenBurnBarMediaCapabilities media_capability_probe(void);

#ifdef __cplusplus
}
#endif

#endif
