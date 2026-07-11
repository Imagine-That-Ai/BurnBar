using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Loop;
using OpenBurnBar.ComputerUse.Windows;

namespace OpenBurnBar.App.ComputerUse;

/// <summary>Process owner for the shipping Windows Computer Use adapters and audit archive.</summary>
internal sealed class WindowsComputerUseRuntimeHost : IComputerUseAuditService, IComputerUseSessionService
{
    private static readonly object StaticGate = new();
    private static WindowsComputerUseRuntimeHost? _current;

    private readonly object _gate = new();
    private readonly string _auditDirectory;
    private readonly ComputerUseAuditArchive _archive;
    private readonly FileKillSwitchFlag _killFlag;
    private readonly KillSwitchStateMachine _killSwitch;
    private readonly SendInputInputSynthesizer _input;
    private readonly UiaInspector _inspector;
    private ComputerUseRuntimeSession? _session;

    private WindowsComputerUseRuntimeHost(string settingsDirectory)
    {
        string root = Path.Combine(settingsDirectory, "computer-use");
        _auditDirectory = Path.Combine(root, "audit");
        _archive = new ComputerUseAuditArchive(_auditDirectory, Path.Combine(root, "exports"));
        _killFlag = new FileKillSwitchFlag(Path.Combine(root, "kill-switch.flag"));
        _killSwitch = new KillSwitchStateMachine(_killFlag);
        _input = new SendInputInputSynthesizer();
        _inspector = new UiaInspector();
    }

    public static WindowsComputerUseRuntimeHost Current => _current
        ?? throw new InvalidOperationException("Windows Computer Use runtime was requested before app launch configuration.");

    public static void Configure(string settingsDirectory)
    {
        lock (StaticGate)
        {
            _current ??= new WindowsComputerUseRuntimeHost(settingsDirectory);
        }
    }

    public static void TryEndSession()
    {
        lock (StaticGate)
        {
            _current?.EndSession();
        }
    }

    public bool SupportsNonBypassableInput => _input.RoutesThroughSignedDriver;

    public ComputerUseSessionStartResult StartSession(ComputerUseTrustMode trustMode, DateTimeOffset startedAt)
    {
        lock (_gate)
        {
            if (_session?.IsActive == true)
            {
                return ComputerUseSessionStartResult.Fail("A Computer Use session is already active.");
            }

            _killSwitch.Reset();
            string sessionId = $"windows-{startedAt:yyyyMMddTHHmmssfffZ}-{Guid.NewGuid():N}";
            string userId = AppConfiguration.Current.EffectiveFirebaseUid() ?? "windows-local-user";
            var manifest = new ComputerUseSessionManifest(
                sessionId,
                ComputerUseMode.System,
                trustMode,
                startedAt,
                userId,
                entitlementProductId: "computer_use_windows",
                actionCap: 500,
                sessionTimeoutSeconds: 30 * 60,
                macHostNodeId: Environment.MachineName);
            try
            {
                _session = new ComputerUseRuntimeSession(
                    manifest,
                    _auditDirectory,
                    AppVersion(),
                    _input,
                    _inspector,
                    _killSwitch);
                return ComputerUseSessionStartResult.Started(sessionId);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return ComputerUseSessionStartResult.Fail($"Computer Use audit session could not start: {ex.Message}");
            }
        }
    }

    public void EndSession()
    {
        lock (_gate)
        {
            _session?.End();
            _session = null;
        }
    }

    /// <summary>Product dispatch entry point after the capability gate has approved an action.</summary>
    public Task<ComputerUseLoopResult> DispatchApprovedAsync(
        MacInputAction action,
        IDaemonApprovalChannel approvalChannel,
        CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_session is null)
            {
                return Task.FromResult(ComputerUseLoopResult.Denied(
                    ComputerUseDenyReason.ConcurrentSession,
                    "session_inactive"));
            }

            return _session.RequestApprovalAndDispatchAsync(action, approvalChannel, cancellationToken: cancellationToken);
        }
    }

    public async Task<ScreenCapture> CaptureWindowAsync(IntPtr hwnd, CancellationToken cancellationToken = default)
    {
        using WindowsGraphicsCaptureScreenCapturer capturer = WindowsGraphicsCaptureFactory.CreateForWindow(hwnd);
        return await capturer.CaptureAsync(cancellationToken).ConfigureAwait(false);
    }

    public AuditActionResult ValidateChain(string sessionId)
    {
        AuditArchiveResult result = _archive.Validate(sessionId);
        return result.Success ? AuditActionResult.Ok(result.Message) : AuditActionResult.Fail(result.Message);
    }

    public AuditActionResult ExportArchive(string sessionId, bool includeScreenshots)
    {
        AuditArchiveResult result = _archive.Export(sessionId, includeScreenshots);
        return result.Success
            ? AuditActionResult.Ok($"{result.Message} {result.ArtifactPath}")
            : AuditActionResult.Fail(result.Message);
    }

    public AuditActionResult Notarize(string sessionId) =>
        AuditActionResult.Fail("Audit notarization requires the authenticated production notarization service.");

    private static string AppVersion() =>
        typeof(WindowsComputerUseRuntimeHost).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion
        ?? typeof(WindowsComputerUseRuntimeHost).Assembly.GetName().Version?.ToString()
        ?? "unknown";
}
