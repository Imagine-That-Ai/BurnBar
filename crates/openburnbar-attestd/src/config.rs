use std::path::PathBuf;

use crate::error::{BrokerError, ErrorCode};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub socket_fd: i32,
    pub state_dir: PathBuf,
    pub manifest: PathBuf,
    pub manifest_signature: PathBuf,
    pub public_key: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InitializeAkConfig {
    pub state_dir: PathBuf,
    pub ek_context: PathBuf,
    pub ek_public: PathBuf,
    pub ek_certificate: PathBuf,
    pub agent_id: String,
    pub tpm2_createak: PathBuf,
    pub rotate: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BrokerCommand {
    Serve(Config),
    InitializeAk(InitializeAkConfig),
}

impl Config {
    pub fn from_args(args: impl IntoIterator<Item = String>) -> Result<Self, BrokerError> {
        let mut socket_fd = None;
        let mut state_dir = None;
        let mut manifest = None;
        let mut manifest_signature = None;
        let mut public_key = None;
        let mut args = args.into_iter();
        while let Some(flag) = args.next() {
            let value = args.next().ok_or_else(invalid_cli)?;
            match flag.as_str() {
                "--socket-fd" if socket_fd.is_none() => socket_fd = value.parse::<i32>().ok(),
                "--state-dir" if state_dir.is_none() => state_dir = Some(PathBuf::from(value)),
                "--manifest" if manifest.is_none() => manifest = Some(PathBuf::from(value)),
                "--manifest-signature" if manifest_signature.is_none() => {
                    manifest_signature = Some(PathBuf::from(value));
                }
                "--public-key" if public_key.is_none() => public_key = Some(PathBuf::from(value)),
                _ => return Err(invalid_cli()),
            }
        }
        let config = Self {
            socket_fd: socket_fd.ok_or_else(invalid_cli)?,
            state_dir: state_dir.ok_or_else(invalid_cli)?,
            manifest: manifest.ok_or_else(invalid_cli)?,
            manifest_signature: manifest_signature.ok_or_else(invalid_cli)?,
            public_key: public_key.ok_or_else(invalid_cli)?,
        };
        if config.socket_fd != 3
            || !config.state_dir.is_absolute()
            || !config.manifest.is_absolute()
            || !config.manifest_signature.is_absolute()
            || !config.public_key.is_absolute()
        {
            return Err(invalid_cli());
        }
        Ok(config)
    }
}

impl BrokerCommand {
    pub fn from_args(args: impl IntoIterator<Item = String>) -> Result<Self, BrokerError> {
        let args = args.into_iter().collect::<Vec<_>>();
        if args.first().is_some_and(|value| value == "initialize-ak") {
            return Ok(Self::InitializeAk(InitializeAkConfig::from_args(
                args.into_iter().skip(1),
            )?));
        }
        Ok(Self::Serve(Config::from_args(args)?))
    }
}

impl InitializeAkConfig {
    pub fn from_args(args: impl IntoIterator<Item = String>) -> Result<Self, BrokerError> {
        let mut state_dir = None;
        let mut ek_context = None;
        let mut ek_public = None;
        let mut ek_certificate = None;
        let mut agent_id = None;
        let mut tpm2_createak = None;
        let mut rotate = false;
        let mut args = args.into_iter().peekable();
        while let Some(flag) = args.next() {
            if flag == "--rotate" && !rotate {
                rotate = true;
                continue;
            }
            let value = args.next().ok_or_else(invalid_cli)?;
            match flag.as_str() {
                "--state-dir" if state_dir.is_none() => state_dir = Some(PathBuf::from(value)),
                "--ek-context" if ek_context.is_none() => ek_context = Some(PathBuf::from(value)),
                "--ek-public" if ek_public.is_none() => ek_public = Some(PathBuf::from(value)),
                "--ek-certificate" if ek_certificate.is_none() => {
                    ek_certificate = Some(PathBuf::from(value));
                }
                "--agent-id" if agent_id.is_none() => agent_id = Some(value),
                "--tpm2-createak" if tpm2_createak.is_none() => {
                    tpm2_createak = Some(PathBuf::from(value));
                }
                _ => return Err(invalid_cli()),
            }
        }
        let config = Self {
            state_dir: state_dir.ok_or_else(invalid_cli)?,
            ek_context: ek_context.ok_or_else(invalid_cli)?,
            ek_public: ek_public.ok_or_else(invalid_cli)?,
            ek_certificate: ek_certificate.ok_or_else(invalid_cli)?,
            agent_id: agent_id.ok_or_else(invalid_cli)?,
            tpm2_createak: tpm2_createak.unwrap_or_else(|| PathBuf::from("/usr/bin/tpm2_createak")),
            rotate,
        };
        if !config.state_dir.is_absolute()
            || !config.ek_context.is_absolute()
            || !config.ek_public.is_absolute()
            || !config.ek_certificate.is_absolute()
            || !config.tpm2_createak.is_absolute()
            || !valid_uuid(&config.agent_id)
        {
            return Err(invalid_cli());
        }
        Ok(config)
    }
}

const fn invalid_cli() -> BrokerError {
    BrokerError::new(
        ErrorCode::Internal,
        "required broker service arguments are invalid",
        false,
    )
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_args() -> Vec<String> {
        [
            "--socket-fd",
            "3",
            "--state-dir",
            "/var/lib/openburnbar-attestd",
            "--manifest",
            "/usr/share/openburnbar/attestation/installed-manifest.json",
            "--manifest-signature",
            "/usr/share/openburnbar/attestation/installed-manifest.json.sig",
            "--public-key",
            "/usr/share/openburnbar/attestation/release-ed25519.pub.pem",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }

    #[test]
    fn parses_exact_service_contract() {
        let parsed = Config::from_args(valid_args());
        assert!(parsed.is_ok());
        assert_eq!(parsed.ok().map(|value| value.socket_fd), Some(3));
    }

    #[test]
    fn rejects_invalid_service_arguments() {
        let mut cases = Vec::new();
        let mut missing = valid_args();
        missing.truncate(missing.len().saturating_sub(2));
        cases.push(missing);
        let mut duplicate = valid_args();
        duplicate.extend(["--socket-fd".to_owned(), "3".to_owned()]);
        cases.push(duplicate);
        let mut unknown = valid_args();
        unknown.extend(["--debug".to_owned(), "true".to_owned()]);
        cases.push(unknown);
        let mut relative = valid_args();
        relative[5] = "relative.json".to_owned();
        cases.push(relative);
        let mut wrong_fd = valid_args();
        wrong_fd[1] = "4".to_owned();
        cases.push(wrong_fd);
        for args in cases {
            assert!(Config::from_args(args).is_err());
        }
    }

    fn valid_initialize_args() -> Vec<String> {
        [
            "initialize-ak",
            "--state-dir",
            "/var/lib/openburnbar-attestd",
            "--ek-context",
            "/var/lib/openburnbar-attestd/ek.ctx",
            "--ek-public",
            "/var/lib/openburnbar-attestd/ek.pub",
            "--ek-certificate",
            "/var/lib/openburnbar-attestd/ek.cert",
            "--agent-id",
            "01234567-89ab-cdef-0123-456789abcdef",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }

    #[test]
    fn parses_initialize_ak_subcommand_without_weakening_service_contract() {
        let parsed = BrokerCommand::from_args(valid_initialize_args());
        assert!(matches!(
            parsed,
            Ok(BrokerCommand::InitializeAk(InitializeAkConfig {
                rotate: false,
                ..
            }))
        ));

        let mut with_rotate = valid_initialize_args();
        with_rotate.push("--rotate".to_owned());
        assert!(matches!(
            BrokerCommand::from_args(with_rotate),
            Ok(BrokerCommand::InitializeAk(InitializeAkConfig {
                rotate: true,
                ..
            }))
        ));
    }

    #[test]
    fn rejects_invalid_initialize_ak_arguments() {
        let mut relative = valid_initialize_args();
        relative[2] = "relative".to_owned();
        assert!(BrokerCommand::from_args(relative).is_err());

        let mut bad_agent = valid_initialize_args();
        bad_agent[10] = "not-a-uuid".to_owned();
        assert!(BrokerCommand::from_args(bad_agent).is_err());

        let mut duplicate_rotate = valid_initialize_args();
        duplicate_rotate.extend(["--rotate".to_owned(), "--rotate".to_owned()]);
        assert!(BrokerCommand::from_args(duplicate_rotate).is_err());
    }
}
