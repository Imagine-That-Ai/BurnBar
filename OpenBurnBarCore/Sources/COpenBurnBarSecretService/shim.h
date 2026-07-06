#pragma once

#include <stddef.h>
#include <stdint.h>

typedef char gchar;
typedef unsigned char guchar;
typedef unsigned long gsize;
typedef int gboolean;
typedef unsigned int GQuark;
typedef int gint;

typedef struct {
    GQuark domain;
    gint code;
    gchar *message;
} GError;

typedef enum {
    OBB_SECRET_SCHEMA_NONE = 0
} OBBSecretSchemaFlags;

typedef enum {
    OBB_SECRET_SCHEMA_ATTRIBUTE_STRING = 0
} OBBSecretSchemaAttributeType;

typedef struct {
    const gchar *name;
    OBBSecretSchemaAttributeType type;
} OBBSecretSchemaAttribute;

typedef struct {
    const gchar *name;
    OBBSecretSchemaFlags flags;
    OBBSecretSchemaAttribute attributes[32];
} OBBSecretSchema;

#define OBB_SECRET_COLLECTION_DEFAULT "default"

extern gchar *secret_password_lookup_sync(
    const OBBSecretSchema *schema,
    void *cancellable,
    GError **error,
    ...
);
extern gboolean secret_password_store_sync(
    const OBBSecretSchema *schema,
    const gchar *collection,
    const gchar *label,
    const gchar *password,
    void *cancellable,
    GError **error,
    ...
);
extern gboolean secret_password_clear_sync(
    const OBBSecretSchema *schema,
    void *cancellable,
    GError **error,
    ...
);
extern void secret_password_free(gchar *password);
extern guchar *g_base64_decode(const gchar *text, gsize *out_len);
extern gchar *g_base64_encode(const guchar *data, gsize len);
extern void g_error_free(GError *error);
extern void g_free(void *mem);
extern gchar *g_strdup(const gchar *str);
extern gchar *g_strdup_printf(const gchar *format, ...);

typedef struct {
    uint8_t *bytes;
    size_t length;
} OBBSecretBytes;

static const OBBSecretSchema obb_secret_service_schema = {
    "com.openburnbar.linux.secrets",
    OBB_SECRET_SCHEMA_NONE,
    {
        { "service", OBB_SECRET_SCHEMA_ATTRIBUTE_STRING },
        { "account", OBB_SECRET_SCHEMA_ATTRIBUTE_STRING },
        { NULL, 0 },
    }
};

static inline void obb_secret_service_string_free(char *value) {
    if (value != NULL) {
        g_free(value);
    }
}

static inline void obb_secret_service_bytes_free(OBBSecretBytes value) {
    if (value.bytes != NULL) {
        g_free(value.bytes);
    }
}

static inline int obb_secret_service_lookup(
    const char *service,
    const char *account,
    OBBSecretBytes *out_secret,
    char **out_error
) {
    if (out_secret != NULL) {
        out_secret->bytes = NULL;
        out_secret->length = 0;
    }
    if (out_error != NULL) {
        *out_error = NULL;
    }

    GError *error = NULL;
    gchar *encoded = secret_password_lookup_sync(
        &obb_secret_service_schema,
        NULL,
        &error,
        "service", service,
        "account", account,
        NULL
    );

    if (error != NULL) {
        if (out_error != NULL) {
            *out_error = g_strdup(error->message);
        }
        g_error_free(error);
        return 2;
    }
    if (encoded == NULL) {
        return 1;
    }

    gsize decoded_length = 0;
    guchar *decoded = g_base64_decode(encoded, &decoded_length);
    secret_password_free(encoded);

    if (decoded == NULL) {
        if (out_error != NULL) {
            *out_error = g_strdup("libsecret value was not valid base64");
        }
        return 2;
    }

    if (out_secret != NULL) {
        out_secret->bytes = decoded;
        out_secret->length = decoded_length;
    } else {
        g_free(decoded);
    }
    return 0;
}

static inline int obb_secret_service_store(
    const char *service,
    const char *account,
    const uint8_t *secret,
    size_t secret_length,
    char **out_error
) {
    if (out_error != NULL) {
        *out_error = NULL;
    }

    gchar *encoded = g_base64_encode(secret, secret_length);
    gchar *label = g_strdup_printf("OpenBurnBar %s", account);
    GError *error = NULL;
    gboolean ok = secret_password_store_sync(
        &obb_secret_service_schema,
        OBB_SECRET_COLLECTION_DEFAULT,
        label,
        encoded,
        NULL,
        &error,
        "service", service,
        "account", account,
        NULL
    );
    g_free(label);
    secret_password_free(encoded);

    if (!ok || error != NULL) {
        if (out_error != NULL) {
            *out_error = g_strdup(error != NULL ? error->message : "libsecret store failed");
        }
        if (error != NULL) {
            g_error_free(error);
        }
        return 2;
    }
    return 0;
}

static inline int obb_secret_service_clear(
    const char *service,
    const char *account,
    char **out_error
) {
    if (out_error != NULL) {
        *out_error = NULL;
    }

    GError *error = NULL;
    gboolean ok = secret_password_clear_sync(
        &obb_secret_service_schema,
        NULL,
        &error,
        "service", service,
        "account", account,
        NULL
    );

    if (!ok && error != NULL) {
        if (out_error != NULL) {
            *out_error = g_strdup(error->message);
        }
        g_error_free(error);
        return 2;
    }
    if (error != NULL) {
        g_error_free(error);
    }
    return 0;
}
