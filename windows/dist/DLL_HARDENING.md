# DLL-load hardening (R19 — the Windows library-validation equivalent)

macOS gives the daemon a **hardened-runtime "library validation"** guarantee: the loader refuses
to load any code not signed by the app's Team ID, so a planted/injected dylib cannot load. Windows
has **no single equivalent**, so the R19 parity is assembled from **three layers**. This file is
the canonical description of all three and how they are wired.

The **single source of truth** for the exact flags is
[`OpenBurnBar.Dist.Hardening/HardeningPolicy.cs`](OpenBurnBar.Dist.Hardening/HardeningPolicy.cs).
The test suite ([`windows/tests/dist/HardeningPolicyTests.cs`](../tests/dist/HardeningPolicyTests.cs))
asserts the packaging props under [`props/`](props) actually carry every flag the policy requires,
so the policy and the shipped props **can never silently drift**.

## Layer 1 — runtime DLL-search hardening (the DLL-planting defense)

`OpenBurnBar.Dist.Hardening.DllSearchHardening.Apply()` calls, on Windows:

```
SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)   // 0x1000
SetDllDirectory("")                                          // drop the CWD from LoadLibrary
```

This removes the **current working directory** and the legacy unsafe search order from every
subsequent `LoadLibrary`, so a DLL planted next to the app/download/CWD cannot hijack a first- or
third-party import. The P/Invoke declarations are pure metadata (they restore on macOS); they only
**execute** on Windows (guarded by `OperatingSystem.IsWindows()`), and the call **never throws** —
a failure is reported via `DllSearchHardeningResult.Applied`.

**Wiring (WINUI-main step, Windows dev host):** call the WinUI-compatible variant *first thing*
in the app entry point, before WinUI resources initialize. The WinUI shell intentionally skips
`SetDefaultDllDirectories` because that breaks Microsoft.UI.Xaml `ms-appx` theme resolution in
unpackaged self-contained runs; it still calls `SetDllDirectory("")` to drop the CWD. Because
WinUI generates `Main`, opt out and provide your own:

```xml
<!-- OpenBurnBar.App.csproj -->
<DefineConstants>$(DefineConstants);DISABLE_XAML_GENERATED_MAIN</DefineConstants>
```

```csharp
// Program.cs
public static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        OpenBurnBar.Dist.Hardening.DllSearchHardening.ApplyWinUICompatible();   // R19 WinUI-safe layer 1
        global::Microsoft.UI.Xaml.Application.Start(_ => _ = new App());
    }
}
```

The app already **references** `OpenBurnBar.Dist.Hardening` and ships this custom `Program.cs`
entry point. Non-XAML helper processes can still use `Apply()` for the stricter
`SetDefaultDllDirectories + SetDllDirectory("")` mode.

## Layer 2 — link-time native hardening

Every in-tree native `.vcxproj` (under `windows/native/`) imports
[`props/OpenBurnBar.Windows.NativeHardening.props`](props/OpenBurnBar.Windows.NativeHardening.props),
which links with:

| Flag | Effect |
| --- | --- |
| `/DEPENDENTLOADFLAG:0x0800` | statically-imported DLLs resolve **only from System32** (`LOAD_LIBRARY_SEARCH_SYSTEM32`) — the load-time analog of layer 1 |
| `/guard:cf` | Control Flow Guard (indirect-call integrity) |
| `/DYNAMICBASE` | ASLR |
| `/HIGHENTROPYVA` | 64-bit high-entropy ASLR |
| `/NXCOMPAT` | DEP |

## Layer 3 — managed PE hardening

The WinUI app imports
[`props/OpenBurnBar.Windows.Hardening.props`](props/OpenBurnBar.Windows.Hardening.props) (wired in
`OpenBurnBar.App.csproj`), which sets `HighEntropyVA=true` (full ASLR entropy on the shipped
managed EXE) and `Deterministic=true` (reproducible, Authenticode-friendly image). This is verified
on macOS: `dotnet msbuild OpenBurnBar.App.csproj -t:Restore -getProperty:HighEntropyVA -p:EnableWindowsTargeting=true`
prints `true`.

## Together = R19

Layer 1 closes the managed-process DLL-planting gap at runtime; layer 2 closes it at load time for
native imports; layer 3 maximizes ASLR entropy. In combination they give the daemon/app a
**library-validation-equivalent** posture: untrusted code adjacent to the app cannot be coerced
into the process image, and what does load is hardened (CFG/DEP/ASLR). It is not byte-for-byte the
same mechanism as macOS library validation, but it is the SOTA Windows assembly of the same
guarantee.
