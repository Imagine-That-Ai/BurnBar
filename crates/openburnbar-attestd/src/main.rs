#[cfg(target_os = "linux")]
fn serve_connection<A, B, R>(
    broker: &openburnbar_attestd::server::Broker<A, B, R>,
    connection: &openburnbar_attestd::linux::SeqpacketConnection,
    deadline: std::time::Duration,
) -> Result<(), openburnbar_attestd::error::BrokerError>
where
    A: openburnbar_attestd::auth::PeerAuthorizer,
    B: openburnbar_attestd::backend::AttestationBackend,
    R: openburnbar_attestd::rate_limit::RequestRateLimiter,
{
    use openburnbar_attestd::server::encode_response;
    use openburnbar_attestd::server::BrokerReply;

    connection.set_deadlines(deadline)?;
    let reply = match connection.receive_request() {
        Ok(packet) => broker.process_packet(&packet.bytes, packet.credentials),
        Err(error) => BrokerReply::failure(String::new(), &error),
    };
    reply.validate()?;
    connection.send_response(
        &encode_response(&reply.response)?,
        reply.evidence_bundle.as_ref(),
    )
}

#[cfg(target_os = "linux")]
fn send_failure(
    connection: &openburnbar_attestd::linux::SeqpacketConnection,
    error: &openburnbar_attestd::error::BrokerError,
) -> Result<(), openburnbar_attestd::error::BrokerError> {
    use openburnbar_attestd::protocol::Response;
    use openburnbar_attestd::server::encode_response;

    connection.send_response(
        &encode_response(&Response::failure(String::new(), error))?,
        None,
    )
}

#[cfg(target_os = "linux")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::path::PathBuf;
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::Duration;

    use openburnbar_attestd::backend::TpmImaAttestationBackend;
    use openburnbar_attestd::config::BrokerCommand;
    use openburnbar_attestd::error::{BrokerError, ErrorCode};
    use openburnbar_attestd::lifecycle::initialize_tpm_ak;
    use openburnbar_attestd::linux::{systemd_listener, ProcPeerAuthorizer, SeqpacketConnection};
    use openburnbar_attestd::rate_limit::PerUidRateLimiter;
    use openburnbar_attestd::server::{Broker, DEFAULT_IO_DEADLINE};
    use openburnbar_attestd::DEFAULT_DAEMON_PATH;

    const WORKER_COUNT: usize = 4;
    const QUEUE_CAPACITY: usize = 16;

    let config = match BrokerCommand::from_args(std::env::args().skip(1))? {
        BrokerCommand::Serve(config) => config,
        BrokerCommand::InitializeAk(config) => {
            let receipt = initialize_tpm_ak(&config)?;
            println!("{}", serde_json::to_string(&receipt)?);
            return Ok(());
        }
    };
    let listener = systemd_listener(config.socket_fd)?;
    let broker = Arc::new(Broker::new(
        ProcPeerAuthorizer::new(
            PathBuf::from(DEFAULT_DAEMON_PATH),
            config.manifest.clone(),
            config.manifest_signature.clone(),
            config.public_key,
        )?,
        TpmImaAttestationBackend::new(
            config.state_dir,
            config.manifest,
            config.manifest_signature,
        )?,
        PerUidRateLimiter::new(4, Duration::from_secs(60))?,
    ));

    let (sender, receiver) = mpsc::sync_channel::<SeqpacketConnection>(QUEUE_CAPACITY);
    let receiver = Arc::new(Mutex::new(receiver));
    let mut _workers = Vec::with_capacity(WORKER_COUNT);
    for index in 0..WORKER_COUNT {
        let broker = Arc::clone(&broker);
        let receiver = Arc::clone(&receiver);
        _workers.push(
            std::thread::Builder::new()
                .name(format!("attestd-{index}"))
                .spawn(move || loop {
                    let connection = match receiver.lock() {
                        Ok(guard) => match guard.recv() {
                            Ok(connection) => connection,
                            Err(_) => return,
                        },
                        Err(_) => return,
                    };
                    if let Err(error) = serve_connection(&broker, &connection, DEFAULT_IO_DEADLINE)
                    {
                        eprintln!("openburnbar-attestd: connection rejected: {error}");
                    }
                })?,
        );
    }

    loop {
        let connection = listener.accept()?;
        match sender.try_send(connection) {
            Ok(()) => {}
            Err(mpsc::TrySendError::Full(connection)) => {
                let error = BrokerError::new(
                    ErrorCode::RateLimited,
                    "broker connection capacity exceeded",
                    true,
                );
                let _deadline_result = connection.set_deadlines(DEFAULT_IO_DEADLINE);
                let _send_result = send_failure(&connection, &error);
            }
            Err(mpsc::TrySendError::Disconnected(_)) => {
                return Err("attestation worker queue disconnected".into());
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("openburnbar-attestd is supported only on Linux");
    std::process::exit(1);
}
