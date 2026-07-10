#![deny(unsafe_code)]

pub mod auth;
pub mod backend;
pub mod config;
pub mod error;
pub mod protocol;
pub mod rate_limit;
pub mod server;

#[cfg(target_os = "linux")]
pub mod linux;

pub const DEFAULT_DAEMON_PATH: &str = "/usr/bin/openburnbar-daemon";
