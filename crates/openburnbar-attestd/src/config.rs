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

const fn invalid_cli() -> BrokerError {
    BrokerError::new(
        ErrorCode::Internal,
        "required broker service arguments are invalid",
        false,
    )
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
}
