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
