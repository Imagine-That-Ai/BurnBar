using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Crypto;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Loop;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using OpenBurnBar.ComputerUse.Windows;

namespace OpenBurnBar.ComputerUse.HostHarness;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static int _exitCode = 2;

    [STAThread]
    private static int Main(string[] args)
    {
        string output = ParseOutput(args);
        Directory.CreateDirectory(output);
        int roInitialize = RoInitialize(0);
        bool shouldUninitialize = roInitialize is 0 or 1;
        if (roInitialize < 0 && roInitialize != unchecked((int)0x80010106))
        {
            Marshal.ThrowExceptionForHR(roInitialize);
        }

        try
        {
            ApplicationConfiguration.Initialize();
            using var form = new ProbeForm();
            form.Shown += async (_, _) =>
            {
                try
                {
                    HostProbeSummary summary = await RunAsync(form, output);
                    File.WriteAllText(
                        Path.Combine(output, "computer-use-host-summary.json"),
                        JsonSerializer.Serialize(summary, JsonOptions));
                    _exitCode = summary.Passed ? 0 : 1;
                }
                catch (Exception ex)
                {
                    File.WriteAllText(
                        Path.Combine(output, "computer-use-host-summary.json"),
                        JsonSerializer.Serialize(new
                        {
                            passed = false,
                            generatedAtUtc = DateTimeOffset.UtcNow,
                            errorType = ex.GetType().FullName,
                            error = ex.Message,
                            stack = ex.StackTrace,
                        }, JsonOptions));
                    _exitCode = 1;
                }
                finally
                {
                    form.Close();
                }
            };
            Application.Run(form);
            return _exitCode;
        }
        finally
        {
            if (shouldUninitialize)
            {
                RoUninitialize();
            }
        }
    }

    private static async Task<HostProbeSummary> RunAsync(ProbeForm form, string output)
    {
        form.Activate();
        SetForegroundWindow(form.Handle);
        await Task.Delay(500);

        var checks = new List<HostProbeCheck>();
        var inspector = new UiaInspector();
        Point normal = form.NormalCenter;
        Point password = form.PasswordCenter;
        Point button = form.ButtonCenter;
        Point dragStart = form.DragStart;
        Point dragEnd = form.DragEnd;
        Point scroll = form.ScrollCenter;

        UiElementInfo normalInfo = inspector.InspectPoint(normal.X, normal.Y);
        UiElementInfo passwordInfo = inspector.InspectPoint(password.X, password.Y);
        Add(checks, "uia-normal-target", !normalInfo.IsPasswordField && !normalInfo.IsSecureDesktop,
            $"process={normalInfo.ProcessImageName}; password={normalInfo.IsPasswordField}");
        Add(checks, "uia-password-target", passwordInfo.IsPasswordField
            && passwordInfo.ClassifyDenyRegion() == OpenBurnBar.ComputerUse.Core.Scope.AccessibilityDenyReason.SecureTextField,
            $"process={passwordInfo.ProcessImageName}; password={passwordInfo.IsPasswordField}; deny={passwordInfo.ClassifyDenyRegion()}");

        var input = new SendInputInputSynthesizer();
        form.FocusNormal();
        InputSynthesisResult focusedNormal = input.Synthesize(new MacInputAction(
            MacInputAction.Kind.Click,
            displayX: normal.X,
            displayY: normal.Y));
        bool normalFocused = await WaitUntilAsync(() => form.NormalFocused);
        Add(checks, "sendinput-focus", focusedNormal.Dispatched && normalFocused,
            $"adapter={focusedNormal.Detail}; focused={normalFocused}");
        string sentinel = "OBB-CU-SENTINEL-20260710";
        InputSynthesisResult typed = input.Synthesize(new MacInputAction(MacInputAction.Kind.Type, text: sentinel));
        bool typedObserved = await WaitUntilAsync(() => form.NormalText == sentinel);
        Add(checks, "sendinput-type", typed.Dispatched && typedObserved, $"adapter={typed.Detail}; observed={typedObserved}");

        InputSynthesisResult selected = input.Synthesize(new MacInputAction(
            MacInputAction.Kind.Shortcut,
            key: "a",
            modifiers: new[] { "ctrl" }));
        InputSynthesisResult replaced = input.Synthesize(new MacInputAction(MacInputAction.Kind.Type, text: "replacement"));
        bool replacementObserved = await WaitUntilAsync(() => form.NormalText == "replacement");
        Add(checks, "sendinput-shortcut", selected.Dispatched && replaced.Dispatched && replacementObserved,
            $"shortcut={selected.Detail}; replacement={replacementObserved}");

        InputSynthesisResult endKey = input.Synthesize(new MacInputAction(MacInputAction.Kind.Key, key: "end"));
        InputSynthesisResult suffix = input.Synthesize(new MacInputAction(MacInputAction.Kind.Type, text: "-end"));
        bool keyObserved = await WaitUntilAsync(() => form.NormalText == "replacement-end");
        Add(checks, "sendinput-key", endKey.Dispatched && suffix.Dispatched && keyObserved,
            $"key={endKey.Detail}; observed={keyObserved}");

        int clicksBefore = form.ClickCount;
        InputSynthesisResult clicked = input.Synthesize(new MacInputAction(
            MacInputAction.Kind.Click,
            displayX: button.X,
            displayY: button.Y));
        bool clickObserved = await WaitUntilAsync(() => form.ClickCount > clicksBefore);
        Add(checks, "sendinput-click", clicked.Dispatched && clickObserved, $"adapter={clicked.Detail}; observed={clickObserved}");

        InputSynthesisResult moved = input.Synthesize(new MacInputAction(
            MacInputAction.Kind.PointerMove,
            displayX: button.X,
            displayY: button.Y));
        clicksBefore = form.ClickCount;
        InputSynthesisResult pointerClicked = input.Synthesize(new MacInputAction(MacInputAction.Kind.PointerClick));
        bool pointerClickObserved = await WaitUntilAsync(() => form.ClickCount > clicksBefore);
        Add(checks, "sendinput-pointer", moved.Dispatched && pointerClicked.Dispatched && pointerClickObserved,
            $"move={moved.Detail}; click={pointerClicked.Detail}; observed={pointerClickObserved}");

        form.ResetDragEvidence();
        InputSynthesisResult dragged = input.Synthesize(new MacInputAction(
            MacInputAction.Kind.DragDrop,
            displayX: dragStart.X,
            displayY: dragStart.Y,
            dragEndX: dragEnd.X,
            dragEndY: dragEnd.Y));
        bool dragObserved = await WaitUntilAsync(() => form.DragCompleted);
        Add(checks, "sendinput-drag", dragged.Dispatched && dragObserved, $"adapter={dragged.Detail}; observed={dragObserved}");

        form.FocusScroll();
        int scrollBefore = form.ScrollOffset;
        int scrollEventsBefore = form.ScrollEvents;
        using (var wheelProbe = new LowLevelMouseWheelProbe())
        {
            InputSynthesisResult scrolled = input.Synthesize(new MacInputAction(
                MacInputAction.Kind.Scroll,
                displayX: scroll.X,
                displayY: scroll.Y,
                deltaY: -2));
            bool scrollObserved = await WaitUntilAsync(() => wheelProbe.InjectedWheelEvents > 0);
            bool controlScrollObserved = form.ScrollOffset != scrollBefore && form.ScrollEvents > scrollEventsBefore;
            Add(checks, "sendinput-scroll", scrolled.Dispatched && scrollObserved && controlScrollObserved,
                $"adapter={scrolled.Detail}; injectedWheelEvents={wheelProbe.InjectedWheelEvents}; controlBefore={scrollBefore}; controlAfter={form.ScrollOffset}; controlEvents={form.ScrollEvents - scrollEventsBefore}");
        }

        string runtimeRoot = Path.Combine(output, "runtime");
        var flag = new FileKillSwitchFlag(Path.Combine(runtimeRoot, "kill-switch.flag"));
        var kill = new KillSwitchStateMachine(flag);
        string auditSessionId = $"host-certification-{DateTimeOffset.UtcNow:yyyyMMddTHHmmssfffZ}-{Guid.NewGuid():N}";
        var manifest = new ComputerUseSessionManifest(
            auditSessionId,
            ComputerUseMode.System,
            ComputerUseTrustMode.Manual,
            DateTimeOffset.UtcNow,
            "certification-user",
            "computer_use_windows",
            actionCap: 50,
            sessionTimeoutSeconds: 300,
            macHostNodeId: Environment.MachineName);
        var runtime = new ComputerUseRuntimeSession(
            manifest,
            runtimeRoot,
            "host-certification",
            input,
            inspector,
            kill);

        string beforeRouteDeny = form.NormalText;
        ComputerUseLoopResult routeDenied = runtime.DispatchAlreadyApproved(
            new MacInputAction(MacInputAction.Kind.Type, text: "must-not-route"),
            AuditApprovedBy.Mac,
            "cert-route-deny");
        await Task.Delay(150);
        Add(checks, "runtime-signed-driver-gate",
            !routeDenied.Succeeded
            && routeDenied.DenyReason == ComputerUseDenyReason.SignatureFailure
            && form.NormalText == beforeRouteDeny,
            $"deny={routeDenied.DenyReason}; detail={routeDenied.Detail}; textUnchanged={form.NormalText == beforeRouteDeny}");

        ComputerUseLoopResult passwordDenied = runtime.DispatchAlreadyApproved(
            new MacInputAction(MacInputAction.Kind.PointerMove, displayX: password.X, displayY: password.Y),
            AuditApprovedBy.Mac,
            "cert-password-deny");
        Add(checks, "runtime-secure-field-deny",
            !passwordDenied.Succeeded && passwordDenied.DenyReason == ComputerUseDenyReason.DenyRegion,
            $"deny={passwordDenied.DenyReason}; detail={passwordDenied.Detail}");

        var watchdog = new WatchdogServer(flag);
        string activateResponse = Encoding.UTF8.GetString(watchdog.Handle(WatchdogCommand.Encode("activate", "host-certification"))).Trim();
        ComputerUseLoopResult watchdogDenied = runtime.DispatchAlreadyApproved(
            new MacInputAction(MacInputAction.Kind.PointerMove, displayX: normal.X, displayY: normal.Y),
            AuditApprovedBy.Mac,
            "cert-watchdog-deny");
        string healthResponse = Encoding.UTF8.GetString(watchdog.Handle(WatchdogCommand.Encode("health"))).Trim();
        string clearResponse = Encoding.UTF8.GetString(watchdog.Handle(WatchdogCommand.Encode("clear"))).Trim();
        ComputerUseLoopResult afterClear = runtime.DispatchAlreadyApproved(
            new MacInputAction(MacInputAction.Kind.PointerMove, displayX: normal.X, displayY: normal.Y),
            AuditApprovedBy.Mac,
            "cert-watchdog-clear");
        Add(checks, "watchdog-kill-and-clear",
            flag.IsActive == false
            && !watchdogDenied.Succeeded
            && watchdogDenied.DenyReason == ComputerUseDenyReason.KillSwitch
            && afterClear.Succeeded
            && activateResponse.Contains("activated", StringComparison.Ordinal)
            && healthResponse.Contains("active", StringComparison.Ordinal)
            && clearResponse.Contains("cleared", StringComparison.Ordinal),
            $"activate={activateResponse}; health={healthResponse}; clear={clearResponse}; denied={watchdogDenied.DenyReason}; afterClear={afterClear.Succeeded}");

        AuditArchiveResult audit = new ComputerUseAuditArchive(runtimeRoot).Validate(runtime.SessionId);
        Add(checks, "audit-chain", audit.Success && audit.EntryCount >= 4,
            $"success={audit.Success}; entries={audit.EntryCount}; head={audit.HeadHashHex}; message={audit.Message}");

        string capturePath = Path.Combine(output, "computer-use-wgc.png");
        using (WindowsGraphicsCaptureScreenCapturer capturer = WindowsGraphicsCaptureFactory.CreateForWindow(form.Handle))
        {
            ScreenCapture capture = await capturer.CaptureAsync();
            File.WriteAllBytes(capturePath, capture.PngBytes);
            bool pngSignature = capture.PngBytes.Length > 8
                && capture.PngBytes[0] == 0x89
                && capture.PngBytes[1] == 0x50
                && capture.PngBytes[2] == 0x4E
                && capture.PngBytes[3] == 0x47;
            string recomputed = AuditHasher.Current.Hash(capture.PngBytes);
            Add(checks, "windows-graphics-capture",
                pngSignature && capture.PngBytes.Length > 4096 && recomputed == capture.ContentHashHex,
                $"bytes={capture.PngBytes.Length}; hash={capture.ContentHashHex}; png={pngSignature}");
        }

        string harnessPath = typeof(Program).Assembly.Location;
        string harnessHash = File.Exists(harnessPath) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(harnessPath))).ToLowerInvariant() : string.Empty;
        return new HostProbeSummary(
            Passed: checks.TrueForAll(check => check.Passed),
            GeneratedAtUtc: DateTimeOffset.UtcNow,
            MachineName: Environment.MachineName,
            OsVersion: Environment.OSVersion.VersionString,
            OsArchitecture: RuntimeInformation.OSArchitecture.ToString(),
            ProcessArchitecture: RuntimeInformation.ProcessArchitecture.ToString(),
            Framework: RuntimeInformation.FrameworkDescription,
            Hwnd: form.Handle.ToInt64(),
            AdapterRoutesThroughSignedDriver: input.RoutesThroughSignedDriver,
            AuditSessionId: runtime.SessionId,
            AuditHeadHash: audit.HeadHashHex,
            CaptureFile: Path.GetFileName(capturePath),
            HarnessSha256: harnessHash,
            Checks: checks);
    }

    private static void Add(List<HostProbeCheck> checks, string name, bool passed, string detail) =>
        checks.Add(new HostProbeCheck(name, passed, detail));

    private static async Task<bool> WaitUntilAsync(Func<bool> condition, int timeoutMilliseconds = 3000)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow.AddMilliseconds(timeoutMilliseconds);
        while (DateTimeOffset.UtcNow < deadline)
        {
            Application.DoEvents();
            if (condition())
            {
                return true;
            }

            await Task.Delay(40);
        }

        return condition();
    }

    private static string ParseOutput(string[] args)
    {
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (string.Equals(args[i], "--output", StringComparison.OrdinalIgnoreCase))
            {
                return Path.GetFullPath(args[i + 1]);
            }
        }

        return Path.Combine(Environment.CurrentDirectory, ".artifacts", "computer-use-host", DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssZ"));
    }

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("combase.dll")]
    private static extern int RoInitialize(int initType);

    [DllImport("combase.dll")]
    private static extern void RoUninitialize();
}

internal sealed record HostProbeCheck(string Name, bool Passed, string Detail);

internal sealed record HostProbeSummary(
    bool Passed,
    DateTimeOffset GeneratedAtUtc,
    string MachineName,
    string OsVersion,
    string OsArchitecture,
    string ProcessArchitecture,
    string Framework,
    long Hwnd,
    bool AdapterRoutesThroughSignedDriver,
    string AuditSessionId,
    string? AuditHeadHash,
    string CaptureFile,
    string HarnessSha256,
    IReadOnlyList<HostProbeCheck> Checks);

internal sealed class ProbeForm : Form
{
    private readonly TextBox _normal = new();
    private readonly TextBox _password = new();
    private readonly Button _button = new();
    private readonly Panel _drag = new();
    private readonly ListBox _scroll = new();
    private bool _dragDown;

    public ProbeForm()
    {
        Text = "OpenBurnBar Computer Use Host Certification";
        ClientSize = new Size(900, 560);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        TopMost = true;

        Controls.Add(Label("Normal input target", 32, 30));
        _normal.SetBounds(32, 58, 390, 36);
        _normal.AccessibleName = "Computer Use normal input target";
        Controls.Add(_normal);

        Controls.Add(Label("Password target (must be denied)", 32, 115));
        _password.SetBounds(32, 143, 390, 36);
        _password.UseSystemPasswordChar = true;
        _password.AccessibleName = "Computer Use password target";
        Controls.Add(_password);

        _button.Text = "Input probe";
        _button.SetBounds(32, 206, 180, 44);
        _button.Click += (_, _) => ClickCount++;
        Controls.Add(_button);

        Controls.Add(Label("Drag probe", 32, 276));
        _drag.SetBounds(32, 306, 390, 120);
        _drag.BackColor = Color.FromArgb(225, 236, 246);
        _drag.BorderStyle = BorderStyle.FixedSingle;
        _drag.MouseDown += (_, _) => _dragDown = true;
        _drag.MouseUp += (_, _) =>
        {
            DragCompleted = _dragDown;
            _dragDown = false;
        };
        Controls.Add(_drag);

        Controls.Add(Label("Scroll probe", 490, 30));
        _scroll.SetBounds(490, 58, 360, 368);
        _scroll.IntegralHeight = false;
        for (int i = 0; i < 40; i++)
        {
            _scroll.Items.Add($"Scroll row {i + 1}");
        }
        _scroll.MouseWheel += (_, _) => ScrollEvents++;

        var status = Label("No production data or credentials are loaded by this certification window.", 32, 475);
        status.AutoSize = false;
        status.Size = new Size(818, 42);
        Controls.Add(status);
    }

    public int ClickCount { get; private set; }

    public bool DragCompleted { get; private set; }

    public string NormalText => _normal.Text;

    public bool NormalFocused => _normal.Focused;

    public int ScrollOffset => _scroll.TopIndex;

    public int ScrollEvents { get; private set; }

    public Point NormalCenter => Center(_normal);

    public Point PasswordCenter => Center(_password);

    public Point ButtonCenter => Center(_button);

    public Point DragStart => _drag.PointToScreen(new Point(40, 60));

    public Point DragEnd => _drag.PointToScreen(new Point(_drag.Width - 40, 60));

    public Point ScrollCenter => Center(_scroll);

    public void FocusNormal()
    {
        Activate();
        _normal.Focus();
        _normal.SelectAll();
    }

    public void FocusScroll()
    {
        Activate();
        _scroll.Focus();
    }

    public void ResetDragEvidence()
    {
        _dragDown = false;
        DragCompleted = false;
    }

    private static Label Label(string text, int x, int y) => new()
    {
        AutoSize = true,
        Location = new Point(x, y),
        Text = text,
    };

    private static Point Center(Control control) =>
        control.PointToScreen(new Point(control.Width / 2, control.Height / 2));
}

internal sealed class LowLevelMouseWheelProbe : IDisposable
{
    private const int WhMouseLl = 14;
    private const int WmMouseWheel = 0x020A;
    private const int WmMouseHWheel = 0x020E;
    private const uint LlmhfInjected = 0x00000001;

    private readonly HookProc _callback;
    private IntPtr _hook;

    public LowLevelMouseWheelProbe()
    {
        _callback = OnHook;
        _hook = SetWindowsHookEx(WhMouseLl, _callback, GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero)
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SetWindowsHookEx(WH_MOUSE_LL) failed.");
        }
    }

    public int InjectedWheelEvents { get; private set; }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }

    private IntPtr OnHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam.ToInt32() == WmMouseWheel || wParam.ToInt32() == WmMouseHWheel))
        {
            MouseHookData data = Marshal.PtrToStructure<MouseHookData>(lParam);
            if ((data.Flags & LlmhfInjected) != 0)
            {
                InjectedWheelEvents++;
            }
        }

        return CallNextHookEx(_hook, code, wParam, lParam);
    }

    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseHookData
    {
        public Point Point;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? moduleName);
}
