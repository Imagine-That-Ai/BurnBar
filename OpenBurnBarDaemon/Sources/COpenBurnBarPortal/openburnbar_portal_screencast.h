#ifndef OPENBURNBAR_PORTAL_SCREENCAST_H
#define OPENBURNBAR_PORTAL_SCREENCAST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OPENBURNBAR_PORTAL_SESSION_HANDLE_MAX 256
#define OPENBURNBAR_PORTAL_ERROR_MESSAGE_MAX 512

typedef struct OpenBurnBarPortalScreenCastGrant {
    int32_t pipewire_fd;
    uint32_t pipewire_node_id;
    char session_handle[OPENBURNBAR_PORTAL_SESSION_HANDLE_MAX];
    uint8_t live;
} OpenBurnBarPortalScreenCastGrant;

typedef struct OpenBurnBarPortalError {
    int32_t code;
    char message[OPENBURNBAR_PORTAL_ERROR_MESSAGE_MAX];
} OpenBurnBarPortalError;

int32_t openburnbar_portal_screencast_acquire(
    uint32_t source_types,
    uint32_t cursor_mode,
    uint32_t timeout_ms,
    OpenBurnBarPortalScreenCastGrant *grant,
    OpenBurnBarPortalError *error
);

void openburnbar_portal_screencast_close(const char *session_handle);

#ifdef __cplusplus
}
#endif

#endif
