// Platform-adapter seams the Windows project implements.
//
// The policy/crypto core NEVER calls a Windows API directly; it drives these
// interfaces. The Windows adapter project (OpenBurnBar.ComputerUse.Windows)
// supplies:
//   * IInputSynthesizer     -> SendInput / ViGEm       (SendInputInputSynthesizer)
//   * IUiInspector          -> IUIAutomation            (UiaInspector)
//   * IScreenCapturer       -> Windows.Graphics.Capture (WindowsGraphicsCaptureScreenCapturer)
//   * IDaemonApprovalChannel-> named-pipe peer-auth      (NamedPipeDaemonApprovalChannel)
//
// Keeping the seams here lets the whole gate + kill-switch + audit pipeline be
// exercised end-to-end on the macOS authoring host with fake adapters.

using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.Scope;

namespace OpenBurnBar.ComputerUse.Core.Adapters;

/// <summary>Outcome of a synthesized input attempt.</summary>
public readonly struct InputSynthesisResult
{
    public InputSynthesisResult(bool dispatched, string detail)
    {
        Dispatched = dispatched;
        Detail = detail;
    }

    public bool Dispatched { get; }

    public string Detail { get; }
}

/// <summary>
/// Synthesizes desktop input for a gate-approved action.
///
/// R17: on Windows, <c>SendInput</c> makes the capability-token gate ADVISORY —
/// any process at the same integrity level can inject the same input, so the
/// token cannot make a SendInput action non-bypassable. Non-bypassable actions
/// (secure-desktop / lock-screen / cross-integrity) MUST route through a signed
/// virtual-HID driver (ViGEm v1; WHQL driver v1.1). Implementations advertise
/// which path they used via <see cref="RoutesThroughSignedDriver"/> so the
/// dispatcher can refuse a non-bypassable action that only SendInput can serve.
/// </summary>
public interface IInputSynthesizer
{
    /// <summary>True iff this synthesizer routes through a signed virtual-HID driver
    /// (ViGEm/WHQL) rather than advisory SendInput.</summary>
    bool RoutesThroughSignedDriver { get; }

    /// <summary>Synthesizes <paramref name="action"/>. The caller has already run the
    /// capability gate, deny-region check, and kill-switch check.</summary>
    InputSynthesisResult Synthesize(MacInputAction action);
}

/// <summary>What a UIA point/window probe returned about a target.</summary>
public sealed class UiElementInfo
{
    public UiElementInfo(
        string? processImageName,
        string? windowTitle,
        bool isPasswordField,
        bool isSecureDesktop,
        bool isCredentialPrompt)
    {
        ProcessImageName = processImageName;
        WindowTitle = windowTitle;
        IsPasswordField = isPasswordField;
        IsSecureDesktop = isSecureDesktop;
        IsCredentialPrompt = isCredentialPrompt;
    }

    public string? ProcessImageName { get; }

    public string? WindowTitle { get; }

    public bool IsPasswordField { get; }

    public bool IsSecureDesktop { get; }

    public bool IsCredentialPrompt { get; }

    /// <summary>The scope context this element presents to the rule matcher.</summary>
    public ScopeContext ToScopeContext(string? url = null)
        => new(url: url, bundleId: ProcessImageName, windowTitle: WindowTitle);

    /// <summary>
    /// Classifies a fast-reject deny reason from the probe. A secure text field,
    /// secure-desktop sheet, or credential prompt is a deny region regardless of
    /// the rule set. Returns null when the element is not itself a deny region.
    /// </summary>
    public AccessibilityDenyReason? ClassifyDenyRegion()
    {
        if (IsPasswordField)
        {
            return AccessibilityDenyReason.SecureTextField;
        }

        if (IsSecureDesktop)
        {
            return AccessibilityDenyReason.SystemAuthSheet;
        }

        if (IsCredentialPrompt)
        {
            return AccessibilityDenyReason.KeychainPrompt;
        }

        return null;
    }
}

/// <summary>Read-only desktop inspection via UIA.</summary>
public interface IUiInspector
{
    /// <summary>Inspects the element under a screen point.</summary>
    UiElementInfo InspectPoint(int displayX, int displayY);

    /// <summary>Inspects the frontmost window.</summary>
    UiElementInfo InspectFrontmost();
}

/// <summary>A captured screenshot + its content hash (recorded in the audit chain).</summary>
public sealed class ScreenCapture
{
    public ScreenCapture(byte[] pngBytes, string contentHashHex)
    {
        PngBytes = pngBytes;
        ContentHashHex = contentHashHex;
    }

    public byte[] PngBytes { get; }

    public string ContentHashHex { get; }
}

/// <summary>Screenshot capture via Windows.Graphics.Capture / DXGI.</summary>
public interface IScreenCapturer
{
    /// <summary>Captures the primary display (or the target window) as PNG.</summary>
    Task<ScreenCapture> CaptureAsync(CancellationToken cancellationToken = default);
}

/// <summary>An approval decision returned by the daemon-approval channel.</summary>
public readonly struct ApprovalDecision
{
    public ApprovalDecision(bool approved, string approvalId)
    {
        Approved = approved;
        ApprovalId = approvalId;
    }

    public bool Approved { get; }

    public string ApprovalId { get; }
}

/// <summary>
/// The daemon-approval channel — the app raises an approval request to the
/// privileged daemon over the landed named-pipe peer-auth harness
/// (OpenBurnBar.Pal.Ipc). Returns the operator's decision + an approval id
/// recorded in the audit entry.
/// </summary>
public interface IDaemonApprovalChannel
{
    Task<ApprovalDecision> RequestApprovalAsync(
        ComputerUseAction action,
        string sessionId,
        CancellationToken cancellationToken = default);
}
