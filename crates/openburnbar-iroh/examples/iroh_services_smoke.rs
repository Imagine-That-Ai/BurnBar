use std::time::Duration;

use iroh::{endpoint::presets, Endpoint};
use iroh_services::Client;

const DEFAULT_ENDPOINT_NAME: &str = "openburnbar-smoke";

#[tokio::main]
async fn main() -> Result<(), iroh_services::anyhow::Error> {
    let endpoint_name = std::env::var("OPENBURNBAR_IROH_SERVICES_ENDPOINT_NAME")
        .unwrap_or_else(|_| DEFAULT_ENDPOINT_NAME.to_string());

    let endpoint = Endpoint::bind(presets::N0).await?;
    tokio::time::timeout(Duration::from_secs(10), endpoint.online()).await?;

    let client = Client::builder(&endpoint)
        .api_secret_from_env()?
        .name(endpoint_name.clone())?
        .build()
        .await?;

    client.ping().await?;
    client.push_metrics().await?;

    println!(
        "iroh services smoke ok: endpoint_name={endpoint_name} endpoint_id={}",
        endpoint.id()
    );

    Ok(())
}
