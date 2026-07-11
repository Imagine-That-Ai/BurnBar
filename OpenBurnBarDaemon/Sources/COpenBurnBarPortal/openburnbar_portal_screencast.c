#include "openburnbar_portal_screencast.h"

#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const char *kPortalBusName = "org.freedesktop.portal.Desktop";
static const char *kPortalObjectPath = "/org/freedesktop/portal/desktop";
static const char *kScreenCastInterface = "org.freedesktop.portal.ScreenCast";
static const char *kRequestInterface = "org.freedesktop.portal.Request";
static const char *kSessionInterface = "org.freedesktop.portal.Session";

typedef struct PortalResponseWait {
    GMainLoop *loop;
    guint32 response;
    GVariant *results;
    gboolean completed;
} PortalResponseWait;

static void set_error(OpenBurnBarPortalError *out, int32_t code, const char *message) {
    if (out == NULL) {
        return;
    }
    out->code = code;
    out->message[0] = '\0';
    if (message != NULL) {
        g_strlcpy(out->message, message, OPENBURNBAR_PORTAL_ERROR_MESSAGE_MAX);
    }
}

static void clear_grant(OpenBurnBarPortalScreenCastGrant *grant) {
    if (grant == NULL) {
        return;
    }
    grant->pipewire_fd = -1;
    grant->pipewire_node_id = 0;
    grant->session_handle[0] = '\0';
    grant->live = 0;
}

static void copy_token(char *buffer, size_t buffer_len, const char *prefix) {
    static gint counter = 0;
    gint next = g_atomic_int_add(&counter, 1) + 1;
    g_snprintf(buffer, buffer_len, "obb_%s_%ld_%d", prefix, (long)getpid(), next);
}

static void response_signal(
    GDBusConnection *connection,
    const gchar *sender_name,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *signal_name,
    GVariant *parameters,
    gpointer user_data
) {
    (void)connection;
    (void)sender_name;
    (void)object_path;
    (void)interface_name;
    (void)signal_name;
    PortalResponseWait *wait = (PortalResponseWait *)user_data;
    if (wait == NULL || parameters == NULL) {
        return;
    }
    if (wait->results != NULL) {
        g_variant_unref(wait->results);
        wait->results = NULL;
    }
    g_variant_get(parameters, "(u@a{sv})", &wait->response, &wait->results);
    wait->completed = TRUE;
    g_main_loop_quit(wait->loop);
}

static gboolean response_timeout(gpointer user_data) {
    PortalResponseWait *wait = (PortalResponseWait *)user_data;
    if (wait != NULL && wait->loop != NULL) {
        g_main_loop_quit(wait->loop);
    }
    return G_SOURCE_REMOVE;
}

static gboolean call_portal_request(
    GDBusConnection *connection,
    const char *method,
    GVariant *parameters,
    guint timeout_ms,
    char *request_path,
    size_t request_path_len,
    OpenBurnBarPortalError *error
) {
    GError *gerror = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        connection,
        kPortalBusName,
        kPortalObjectPath,
        kScreenCastInterface,
        method,
        parameters,
        G_VARIANT_TYPE("(o)"),
        G_DBUS_CALL_FLAGS_NONE,
        (gint)timeout_ms,
        NULL,
        &gerror
    );
    if (reply == NULL) {
        set_error(error, 10, gerror != NULL ? gerror->message : "portal method call failed");
        g_clear_error(&gerror);
        return FALSE;
    }
    const char *handle = NULL;
    g_variant_get(reply, "(&o)", &handle);
    if (handle == NULL || handle[0] == '\0') {
        g_variant_unref(reply);
        set_error(error, 11, "portal returned an empty request handle");
        return FALSE;
    }
    g_strlcpy(request_path, handle, request_path_len);
    g_variant_unref(reply);
    return TRUE;
}

static gboolean wait_for_response(
    GDBusConnection *connection,
    const char *request_path,
    guint timeout_ms,
    guint32 *response,
    GVariant **results,
    OpenBurnBarPortalError *error
) {
    PortalResponseWait wait = {
        .loop = g_main_loop_new(NULL, FALSE),
        .response = 2,
        .results = NULL,
        .completed = FALSE,
    };
    guint subscription = g_dbus_connection_signal_subscribe(
        connection,
        kPortalBusName,
        kRequestInterface,
        "Response",
        request_path,
        NULL,
        G_DBUS_SIGNAL_FLAGS_NONE,
        response_signal,
        &wait,
        NULL
    );
    guint timeout_source = g_timeout_add(timeout_ms, response_timeout, &wait);
    g_main_loop_run(wait.loop);
    if (timeout_source != 0 && wait.completed) {
        g_source_remove(timeout_source);
    }
    g_dbus_connection_signal_unsubscribe(connection, subscription);
    g_main_loop_unref(wait.loop);
    if (!wait.completed) {
        set_error(error, 12, "timed out waiting for portal response");
        return FALSE;
    }
    if (response != NULL) {
        *response = wait.response;
    }
    if (results != NULL) {
        *results = wait.results;
    } else if (wait.results != NULL) {
        g_variant_unref(wait.results);
    }
    return TRUE;
}

static gboolean expect_response_zero(
    GDBusConnection *connection,
    const char *request_path,
    guint timeout_ms,
    GVariant **results,
    OpenBurnBarPortalError *error
) {
    guint32 response = 2;
    if (!wait_for_response(connection, request_path, timeout_ms, &response, results, error)) {
        return FALSE;
    }
    if (response != 0) {
        if (results != NULL && *results != NULL) {
            g_variant_unref(*results);
            *results = NULL;
        }
        set_error(error, (int32_t)(100 + response), "portal screencast consent was denied or cancelled");
        return FALSE;
    }
    return TRUE;
}

static gboolean create_session(
    GDBusConnection *connection,
    guint timeout_ms,
    char *session_handle,
    size_t session_handle_len,
    OpenBurnBarPortalError *error
) {
    char token[64];
    copy_token(token, sizeof(token), "session");
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string(token));

    char request_path[OPENBURNBAR_PORTAL_SESSION_HANDLE_MAX];
    if (!call_portal_request(
            connection,
            "CreateSession",
            g_variant_new("(a{sv})", &options),
            timeout_ms,
            request_path,
            sizeof(request_path),
            error
        )) {
        return FALSE;
    }
    GVariant *results = NULL;
    if (!expect_response_zero(connection, request_path, timeout_ms, &results, error)) {
        return FALSE;
    }
    GVariant *session = g_variant_lookup_value(results, "session_handle", G_VARIANT_TYPE_OBJECT_PATH);
    if (session == NULL) {
        g_variant_unref(results);
        set_error(error, 13, "portal CreateSession response did not include session_handle");
        return FALSE;
    }
    g_strlcpy(session_handle, g_variant_get_string(session, NULL), session_handle_len);
    g_variant_unref(session);
    g_variant_unref(results);
    return TRUE;
}

static gboolean select_sources(
    GDBusConnection *connection,
    const char *session_handle,
    guint32 source_types,
    guint32 cursor_mode,
    guint timeout_ms,
    OpenBurnBarPortalError *error
) {
    char token[64];
    copy_token(token, sizeof(token), "select");
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
    g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(source_types));
    g_variant_builder_add(&options, "{sv}", "multiple", g_variant_new_boolean(FALSE));
    g_variant_builder_add(&options, "{sv}", "cursor_mode", g_variant_new_uint32(cursor_mode));

    char request_path[OPENBURNBAR_PORTAL_SESSION_HANDLE_MAX];
    if (!call_portal_request(
            connection,
            "SelectSources",
            g_variant_new("(oa{sv})", session_handle, &options),
            timeout_ms,
            request_path,
            sizeof(request_path),
            error
        )) {
        return FALSE;
    }
    return expect_response_zero(connection, request_path, timeout_ms, NULL, error);
}

static gboolean start_session(
    GDBusConnection *connection,
    const char *session_handle,
    guint timeout_ms,
    guint32 *node_id,
    OpenBurnBarPortalError *error
) {
    char token[64];
    copy_token(token, sizeof(token), "start");
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));

    char request_path[OPENBURNBAR_PORTAL_SESSION_HANDLE_MAX];
    if (!call_portal_request(
            connection,
            "Start",
            g_variant_new("(osa{sv})", session_handle, "", &options),
            timeout_ms,
            request_path,
            sizeof(request_path),
            error
        )) {
        return FALSE;
    }
    GVariant *results = NULL;
    if (!expect_response_zero(connection, request_path, timeout_ms, &results, error)) {
        return FALSE;
    }
    GVariant *streams = g_variant_lookup_value(results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
    if (streams == NULL) {
        g_variant_unref(results);
        set_error(error, 14, "portal Start response did not include streams");
        return FALSE;
    }
    GVariantIter iter;
    guint32 stream_node = 0;
    GVariant *properties = NULL;
    g_variant_iter_init(&iter, streams);
    gboolean has_stream = g_variant_iter_next(&iter, "(u@a{sv})", &stream_node, &properties);
    if (properties != NULL) {
        g_variant_unref(properties);
    }
    g_variant_unref(streams);
    g_variant_unref(results);
    if (!has_stream) {
        set_error(error, 15, "portal Start returned no PipeWire streams");
        return FALSE;
    }
    *node_id = stream_node;
    return TRUE;
}

static gboolean open_pipewire_remote(
    GDBusConnection *connection,
    const char *session_handle,
    guint timeout_ms,
    gint *pipewire_fd,
    OpenBurnBarPortalError *error
) {
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    GError *gerror = NULL;
    GUnixFDList *fd_list = NULL;
    GVariant *reply = g_dbus_connection_call_with_unix_fd_list_sync(
        connection,
        kPortalBusName,
        kPortalObjectPath,
        kScreenCastInterface,
        "OpenPipeWireRemote",
        g_variant_new("(oa{sv})", session_handle, &options),
        G_VARIANT_TYPE("(h)"),
        G_DBUS_CALL_FLAGS_NONE,
        (gint)timeout_ms,
        NULL,
        &fd_list,
        NULL,
        &gerror
    );
    if (reply == NULL) {
        set_error(error, 16, gerror != NULL ? gerror->message : "OpenPipeWireRemote failed");
        g_clear_error(&gerror);
        return FALSE;
    }
    gint handle = -1;
    g_variant_get(reply, "(h)", &handle);
    g_variant_unref(reply);
    if (fd_list == NULL || handle < 0) {
        g_clear_object(&fd_list);
        set_error(error, 17, "OpenPipeWireRemote returned no fd handle");
        return FALSE;
    }
    gint fd = g_unix_fd_list_get(fd_list, handle, &gerror);
    g_clear_object(&fd_list);
    if (fd < 0) {
        set_error(error, 18, gerror != NULL ? gerror->message : "failed to extract PipeWire fd");
        g_clear_error(&gerror);
        return FALSE;
    }
    *pipewire_fd = fd;
    return TRUE;
}

int32_t openburnbar_portal_screencast_acquire(
    uint32_t source_types,
    uint32_t cursor_mode,
    uint32_t timeout_ms,
    OpenBurnBarPortalScreenCastGrant *grant,
    OpenBurnBarPortalError *error
) {
    clear_grant(grant);
    set_error(error, 0, "");
    if (grant == NULL) {
        set_error(error, 1, "grant output pointer is null");
        return -1;
    }
    guint effective_timeout = timeout_ms == 0 ? 60000 : timeout_ms;
    guint32 effective_sources = source_types == 0 ? 1 : source_types;
    guint32 effective_cursor = cursor_mode == 0 ? 2 : cursor_mode;

    GError *gerror = NULL;
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &gerror);
    if (connection == NULL) {
        set_error(error, 2, gerror != NULL ? gerror->message : "session D-Bus is unavailable");
        g_clear_error(&gerror);
        return -1;
    }

    char session_handle[OPENBURNBAR_PORTAL_SESSION_HANDLE_MAX];
    session_handle[0] = '\0';
    guint32 node_id = 0;
    gint fd = -1;
    gboolean ok = create_session(connection, effective_timeout, session_handle, sizeof(session_handle), error)
        && select_sources(connection, session_handle, effective_sources, effective_cursor, effective_timeout, error)
        && start_session(connection, session_handle, effective_timeout, &node_id, error)
        && open_pipewire_remote(connection, session_handle, effective_timeout, &fd, error);

    g_object_unref(connection);
    if (!ok) {
        if (fd >= 0) {
            close(fd);
        }
        if (session_handle[0] != '\0') {
            openburnbar_portal_screencast_close(session_handle);
        }
        return -1;
    }

    grant->pipewire_fd = fd;
    grant->pipewire_node_id = node_id;
    grant->live = 1;
    g_strlcpy(grant->session_handle, session_handle, OPENBURNBAR_PORTAL_SESSION_HANDLE_MAX);
    return 0;
}

void openburnbar_portal_screencast_close(const char *session_handle) {
    if (session_handle == NULL || session_handle[0] == '\0') {
        return;
    }
    GError *gerror = NULL;
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &gerror);
    if (connection == NULL) {
        g_clear_error(&gerror);
        return;
    }
    GVariant *reply = g_dbus_connection_call_sync(
        connection,
        kPortalBusName,
        session_handle,
        kSessionInterface,
        "Close",
        NULL,
        NULL,
        G_DBUS_CALL_FLAGS_NONE,
        5000,
        NULL,
        &gerror
    );
    if (reply != NULL) {
        g_variant_unref(reply);
    }
    g_clear_error(&gerror);
    g_object_unref(connection);
}
