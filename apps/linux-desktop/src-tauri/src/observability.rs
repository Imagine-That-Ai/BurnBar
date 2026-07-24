//! Privacy-safe crash reporting for the Linux desktop shell.
//!
//! The macOS app and daemon both keep Sentry optional in development, but make
//! a missing production configuration visible. The guard in this module must
//! live for the lifetime of the Tauri application so queued events can drain on
//! a normal shutdown.

use std::borrow::Cow;
use std::env;
use std::sync::Arc;

/// Owns the Sentry client until the Tauri application exits.
pub(crate) struct SentryGuard {
    _client: Option<sentry::ClientInitGuard>,
}

/// Initialise Linux crash reporting without allowing malformed configuration
/// to panic the normal developer build.
pub(crate) fn initialize() -> Result<SentryGuard, String> {
    let raw_dsn = env::var("OPENBURNBAR_SENTRY_DSN")
        .or_else(|_| env::var("BURNBAR_SENTRY_DSN"))
        .ok();
    let Some(raw_dsn) = raw_dsn else {
        return disabled_or_strict("Sentry DSN is not configured");
    };
    let trimmed_dsn = raw_dsn.trim();
    if trimmed_dsn.is_empty() {
        return disabled_or_strict("Sentry DSN is empty");
    }

    let dsn = match trimmed_dsn.parse::<sentry::types::Dsn>() {
        Ok(dsn) => dsn,
        Err(_) => return disabled_or_strict("Sentry DSN is malformed"),
    };

    let mut options = sentry::ClientOptions::new();
    // Assign the already-parsed DSN directly. ClientOptions::dsn(&str) parses
    // internally and panics on invalid input, which is not acceptable at boot.
    options.dsn = Some(dsn);
    options.release = Some(Cow::Borrowed(concat!(
        "openburnbar-linux-desktop@",
        env!("CARGO_PKG_VERSION")
    )));
    options.environment = Some(Cow::Borrowed("linux-desktop"));
    options.send_default_pii = false;
    options.traces_sample_rate = 0.0;
    options.before_send = Some(Arc::new(scrub_event));
    options.before_breadcrumb = Some(Arc::new(scrub_breadcrumb));

    let client = sentry::init(options);
    eprintln!("openburnbar: Sentry crash reporting enabled");
    Ok(SentryGuard {
        _client: Some(client),
    })
}

fn strict_observability_requested() -> bool {
    [
        "OPENBURNBAR_STRICT_OBSERVABILITY",
        "BURNBAR_STRICT_OBSERVABILITY",
    ]
    .iter()
    .filter_map(|name| env::var(name).ok())
    .map(|value| value.trim().to_ascii_lowercase())
    .any(|value| matches!(value.as_str(), "1" | "true" | "yes" | "on"))
}

fn disabled_or_strict(reason: &str) -> Result<SentryGuard, String> {
    let message = format!("Crash reporting is DARK: {reason}");
    if strict_observability_requested() {
        Err(format!(
            "{message}. Provide OPENBURNBAR_SENTRY_DSN or clear strict observability."
        ))
    } else {
        eprintln!("openburnbar: {message}; continuing without Sentry");
        Ok(SentryGuard { _client: None })
    }
}

/// Keep the crash signal while removing fields that can carry user content or
/// local identity. Exception and stacktrace data remain available for diagnosis
/// under the same privacy posture used by the macOS crash reporter.
fn scrub_event(
    mut event: sentry::protocol::Event<'static>,
) -> Option<sentry::protocol::Event<'static>> {
    event.user = None;
    event.request = None;
    event.server_name = None;
    event.message = None;
    event.culprit = None;
    event.transaction = None;
    event.logentry = None;
    event.contexts.clear();
    event.tags.clear();
    event.extra.clear();
    event.breadcrumbs = Default::default();
    for exception in &mut event.exception {
        exception.value = None;
        if let Some(stacktrace) = exception.stacktrace.as_mut() {
            scrub_stacktrace(stacktrace);
        }
        if let Some(stacktrace) = exception.raw_stacktrace.as_mut() {
            scrub_stacktrace(stacktrace);
        }
        if let Some(mechanism) = exception.mechanism.as_mut() {
            mechanism.description = None;
            mechanism.data.clear();
        }
    }
    Some(event)
}

fn scrub_stacktrace(stacktrace: &mut sentry::protocol::Stacktrace) {
    for frame in &mut stacktrace.frames {
        frame.abs_path = None;
        frame.pre_context.clear();
        frame.context_line = None;
        frame.post_context.clear();
        frame.vars.clear();
    }
    stacktrace.registers.clear();
}

/// Drop breadcrumbs rather than risk forwarding prompt text, paths, or tokens.
fn scrub_breadcrumb(_breadcrumb: sentry::Breadcrumb) -> Option<sentry::Breadcrumb> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_dsn_parses_without_initialising_a_client() {
        let dsn = "https://public@sentry.invalid/1".parse::<sentry::types::Dsn>();
        assert!(dsn.is_ok());
    }

    #[test]
    fn malformed_dsn_is_rejected_without_panicking() {
        assert!("not a dsn".parse::<sentry::types::Dsn>().is_err());
    }

    #[test]
    fn scrubber_removes_user_and_request_fields() {
        let mut event = sentry::protocol::Event::new();
        event.message = Some("private prompt".to_string());
        event.tags.insert("account".to_string(), "user".to_string());
        event.extra.insert(
            "secret".to_string(),
            sentry::protocol::Value::String("value".to_string()),
        );
        event.exception.values.push(sentry::protocol::Exception {
            value: Some("private error value".to_string()),
            stacktrace: Some(sentry::protocol::Stacktrace {
                frames: vec![sentry::protocol::Frame {
                    abs_path: Some("/home/alice/private.rs".to_string()),
                    context_line: Some("private prompt".to_string()),
                    ..Default::default()
                }],
                ..Default::default()
            }),
            ..Default::default()
        });

        let scrubbed = scrub_event(event).expect("event should be retained");
        assert!(scrubbed.message.is_none());
        assert!(scrubbed.tags.is_empty());
        assert!(scrubbed.extra.is_empty());
        assert!(scrubbed.breadcrumbs.is_empty());
        assert!(scrubbed.exception[0].value.is_none());
        let frame = &scrubbed.exception[0]
            .stacktrace
            .as_ref()
            .expect("stacktrace retained")
            .frames[0];
        assert!(frame.abs_path.is_none());
        assert!(frame.context_line.is_none());
    }

    #[test]
    fn breadcrumbs_are_dropped() {
        assert!(scrub_breadcrumb(sentry::Breadcrumb::default()).is_none());
    }
}
