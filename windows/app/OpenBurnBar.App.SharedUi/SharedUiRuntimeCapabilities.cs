using System;
using System.Collections.Generic;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// Synthesizes the runtime_capabilities manifest for the Windows host. The
/// frontend decoder (apps/linux-desktop/src/runtimeCapabilities.ts) is strict:
/// all 27 ids exactly once, domain/state enums, non-empty reason + source,
/// schemaVersion === 1. Every route in the shell maps to one capability id and
/// renders a blocked panel (reason + substitute + repair) when the state is
/// unavailable|blocked — so this manifest is the honesty surface for what the
/// Windows backend does and does not serve today.
/// </summary>
public static class SharedUiRuntimeCapabilities
{
    /// <summary>Bumped when the Windows capability catalog changes.</summary>
    public const string CatalogVersion = "windows-2026-07-23";

    // The 27 ids in the pinned RUNTIME_CAPABILITY_IDS order.
    private static readonly string[] CapabilityIds =
    {
        "usage.read", "database.read", "providers.configure", "projects.read",
        "missions.manage", "sessions.read", "chat.gateway", "memory.review",
        "computer-use.browser", "computer-use.system", "media.mercury",
        "smarthub.control", "settings.read", "account.read", "updates.check",
        "updates.install", "support.export", "onboarding.repair", "pet.overlay",
        "text-expansion.in-app", "text-expansion.system", "secrets.secret-service",
        "secrets.kwallet", "portal.desktop", "native.tray", "native.notifications",
        "native.external-billing",
    };

    public static JsonObject BuildManifest(string shellVersion, SharedUiCapabilityStatus status)
    {
        var capabilities = new JsonArray();
        foreach (var id in CapabilityIds)
        {
            var (domain, state, reason, substitute, source) = Describe(id, status);
            var entry = new JsonObject
            {
                ["id"] = id,
                ["domain"] = domain,
                ["state"] = state,
                ["reason"] = reason,
                ["substitute"] = substitute,
                ["source"] = source,
            };
            capabilities.Add(entry);
        }

        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["catalogVersion"] = CatalogVersion,
            ["shellVersion"] = shellVersion,
            ["daemonVersion"] = null,
            ["daemonProtocolVersion"] = null,
            ["sessionType"] = null,
            ["desktop"] = null,
            ["capabilities"] = capabilities,
        };
    }

    private static (string Domain, string State, string Reason, string? Substitute, string Source) Describe(
        string id, SharedUiCapabilityStatus status) =>
        id switch
        {
            "usage.read" => status.StorageReady
                ? Product(id, "available", "Usage events are read from the in-process SQLCipher store.", "windows-storage")
                : Product(id, "unavailable", "The local store is in typed recovery; usage reads are blocked until it resolves.", "windows-storage"),
            "database.read" => status.StorageReady
                ? Product(id, "degraded", "Store status is live; daemon code-memory index RPCs are not served on Windows.", "windows-storage")
                : Product(id, "unavailable", "The local store is in typed recovery.", "windows-storage"),
            "providers.configure" => Product(id, "available",
                "Provider catalog + credential slots are read from the gateway route store; mutations return explicit not-implemented errors.",
                "windows-gateway"),
            "projects.read" => Unavailable(id,
                "Project listing is daemon-backed (daemon.controller.project.list); Windows serves code memory in-process but the shell read path is not wired yet.",
                "Use the native Projects page from the legacy window."),
            "missions.manage" => Unavailable(id,
                "Mission control is daemon-backed (daemon.mission.*); the Windows Firestore dispatch host is not wired into this shell yet.",
                "Use the native Mission Control page from the legacy window."),
            "sessions.read" => status.SessionLogsReady
                ? Product(id, "available", "Session logs are read from the shared SQLCipher FTS index.", "windows-storage")
                : Product(id, "unavailable", "The session-log index is unavailable until storage provisioning completes.", "windows-storage"),
            "chat.gateway" => status.GatewayRunning
                ? Product(id, "available", "The in-process loopback gateway serves OpenAI-compatible chat.", "windows-gateway")
                : Product(id, "degraded", "The local model proxy is not running; chat stays unavailable until it starts.", "windows-gateway"),
            "memory.review" => Unavailable(id,
                "Memory review is daemon-backed (daemon.memory.*); the Windows E2EE inbox is not wired into this shell yet.",
                "Use the native Memory page from the legacy window."),
            "computer-use.browser" => Unavailable(id,
                "Computer Use is approval-gated daemon automation; the Windows computer-use plane is gated separately.",
                null),
            "computer-use.system" => Unavailable(id,
                "Computer Use is approval-gated daemon automation; the Windows computer-use plane is gated separately.",
                null),
            "media.mercury" => Unavailable(id,
                "Mercury media (calls, mirror, file transfer) is daemon-owned; there is no Windows media renderer in this shell.",
                null),
            "smarthub.control" => Unavailable(id,
                "SmartHub control runs through the trusted openburnbar-cli on Linux; no Windows equivalent is installed.",
                null),
            "settings.read" => Product(id, "available",
                "Settings are read from the Windows settings store; privacy toggles persist locally.", "windows-settings"),
            "account.read" => Product(id, "available",
                "Cloud identity is read from the Windows OAuth credentials provider.", "windows-cloudsync"),
            "updates.check" => status.UpdatesConfigured
                ? Delivery(id, "available", "The signed WinSparkle appcast feed is configured.", "windows-updater")
                : Delivery(id, "unavailable", "No update feed is configured for this build.", "windows-updater"),
            "updates.install" => Delivery(id, "unavailable",
                "In-app install is not exposed through this shell on Windows.",
                "The Updates surface opens the signed download page in the system browser.", "windows-updater"),
            "support.export" => Delivery(id, "available",
                "Diagnostics bundles are written by the Windows support-bundle builder.", "windows-diagnostics"),
            "onboarding.repair" => Platform(id, "unavailable",
                "Windows setup is host-local (single process, WPD-0006); there is no daemon onboarding wizard to repair.",
                null, "windows-host"),
            "pet.overlay" => Platform(id, "unavailable",
                "The Windows pet overlay is a native window owned by the app, not an in-shell surface.",
                "Manage the pet from the tray icon or the native Settings window.", "windows-host"),
            "text-expansion.in-app" => Product(id, "available",
                "In-app snippet expansion is shell-local.", "windows-host"),
            "text-expansion.system" => Platform(id, "unavailable",
                "System-wide expansion on Linux is Wayland-portal work; Windows system expansion is a native engine.",
                "The native TextExpansion engine runs outside this shell.", "windows-host"),
            "secrets.secret-service" => Security(id, "unavailable",
                "Linux Secret Service does not exist on Windows.",
                "Credentials live in the Windows DPAPI protected store.", "windows-host"),
            "secrets.kwallet" => Security(id, "unavailable",
                "KWallet is Linux-only.", null, "windows-host"),
            "portal.desktop" => Platform(id, "unavailable",
                "xdg-desktop-portal is Linux-only.", null, "windows-host"),
            "native.tray" => status.TrayReady
                ? Platform(id, "available", "The Shell_NotifyIcon tray is installed.", "windows-tray")
                : Platform(id, "degraded", "Tray registration failed; the shell runs without a tray icon.", "windows-tray"),
            "native.notifications" => status.NotificationsReady
                ? Platform(id, "available", "Windows App Notifications are registered.", "windows-notifications")
                : Platform(id, "unavailable", "The notification plane failed to register.", "windows-notifications"),
            "native.external-billing" => Security(id, "unavailable",
                "Membership billing is daemon-minted on Linux; Windows cloud billing is not wired into this shell yet.",
                "Manage billing from the web portal.", "windows-host"),
            _ => throw new ArgumentOutOfRangeException(nameof(id), id, "Unknown capability id."),
        };

    private static (string, string, string, string?, string) Product(
        string id, string state, string reason, string source) =>
        ("product", state, reason, null, source);

    private static (string, string, string, string?, string) Delivery(
        string id, string state, string reason, string source) =>
        ("delivery", state, reason, null, source);

    private static (string, string, string, string?, string) Delivery(
        string id, string state, string reason, string? substitute, string source) =>
        ("delivery", state, reason, substitute, source);

    private static (string, string, string, string?, string) Platform(
        string id, string state, string reason, string source) =>
        ("platform", state, reason, null, source);

    private static (string, string, string, string?, string) Platform(
        string id, string state, string reason, string? substitute, string source) =>
        ("platform", state, reason, substitute, source);

    private static (string, string, string, string?, string) Security(
        string id, string state, string reason, string? substitute, string source) =>
        ("security", state, reason, substitute, source);

    private static (string, string, string, string?, string) Unavailable(
        string id, string reason, string? substitute) =>
        ("product", "unavailable", reason, substitute, "windows-host");
}
