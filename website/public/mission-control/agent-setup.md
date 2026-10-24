# Configure this installation with your agent

Give this brief to an agent you already trust on your own computer. DMG installs include it inside the app at `Contents/Resources/Setup/AGENT-SETUP.md`; the profile validator is the bundled `Contents/Helpers/FleetService --validate-profile <file>`. You do not need to clone a repository to configure the installed app. The app does not include a paid AI account and does not upload your configuration to a shared service.

> Configure my installed Mission Control. Read the bundled or repository PRODUCT.md and implementation contract. Discover only the local machine and remote machines I identify or already explicitly authorize. Preserve my running jobs and account sessions. Never read, copy or embed private keys, browser sessions or cloud credentials. Propose a schemaVersion 1 JSON profile with my chosen brand name and environments. Use existing SSH config aliases with strict host-key verification. Every action must be an explicit executable plus fixed argument array, with an understandable name and finite timeout. Begin with harmless diagnostics such as hostname and OS version; do not add arbitrary shell, installation, destructive actions, cloud purchases or CI work. If I ask for agent actions, preserve my exact model, effort and account route without fallback. Explain which actions require further permission. Validate the profile, show me the machines and permissions, and let me import it. If you include probeActionID, explain that the selected diagnostic can run automatically every 10 seconds and review its exact executable and arguments with me first. Then verify a real probe and one approved action. Report configured, reachable, authenticated and task-ready separately.

## Profile shape

```json
{
  "schemaVersion": 1,
  "revision": 0,
  "brandName": "My Control Room",
  "environments": [
    {
      "id": "my-mac",
      "name": "My Mac",
      "kind": "mac",
      "connection": { "transport": "local" },
      "actions": [
        {
          "id": "hostname",
          "name": "Check hostname",
          "executable": "/bin/hostname",
          "arguments": [],
          "timeoutSeconds": 10,
          "category": "diagnostic"
        }
      ]
    }
  ]
}
```

Command paths must exist on their target OS. SSH actions run on the target, using the local machine's existing SSH agent/configuration. Optional fields are omitted rather than invented. Changing a profile does not establish authentication to an external AI provider.

## Pairing a phone

iOS is client-only. Use an owner-managed HTTPS endpoint with valid TLS and access controls to reach the Mac service; pair using its token. Keep the service on loopback by default. Do not expose an unauthenticated port or disable certificate validation. A remote-connect failure is a configuration issue to surface, not a reason to bypass a safeguard.

## What a release can promise

The DMG installs the Mac application and bundled service. Your devices, logins, OS permissions and signing identities remain yours. A release should state supported macOS versions/architectures, signature and notarization status, and clean-install evidence. Universal compatibility is a test matrix, not an absolute guarantee.
