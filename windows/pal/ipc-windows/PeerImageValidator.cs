// Validate the peer process image AND its loaded modules.
//
// R16 control: "verify image + loaded modules". Authenticode on the main image
// alone is NOT enough — DLL injection into an otherwise-signed process passes an
// image-only check (R16/R19). This validator therefore:
//   1. WinVerifyTrust's the peer's main executable image, and
//   2. enumerates every loaded module and WinVerifyTrust's each one,
// failing the peer if any module is unsigned/untrusted or lives outside the
// allowlisted trusted directories.
//
// Scaffold for VAL-P0-CONPTY-018. The macOS host cannot enumerate a real
// Windows process's modules, so the LIVE proof (inject an unsigned DLL, confirm
// rejection) is VAL-P0-CONPTY-019 — see the runbook. The verdict types and the
// enumeration/verification flow are exercised on Windows there.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using OpenBurnBar.Pal.Ipc.Windows.Interop;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>Outcome of validating a peer process's image and modules.</summary>
public sealed class PeerImageVerdict
{
    private PeerImageVerdict(bool trusted, string mainImagePath, IReadOnlyList<string> untrustedModules)
    {
        Trusted = trusted;
        MainImagePath = mainImagePath;
        UntrustedModules = untrustedModules;
    }

    /// <summary>True iff the main image and every loaded module verified.</summary>
    public bool Trusted { get; }

    /// <summary>The peer's main executable path.</summary>
    public string MainImagePath { get; }

    /// <summary>Modules that failed Authenticode or the trusted-directory check.
    /// Empty when <see cref="Trusted"/> is true.</summary>
    public IReadOnlyList<string> UntrustedModules { get; }

    internal static PeerImageVerdict TrustedImage(string mainImagePath) =>
        new(trusted: true, mainImagePath, Array.Empty<string>());

    internal static PeerImageVerdict Rejected(string mainImagePath, IReadOnlyList<string> untrusted) =>
        new(trusted: false, mainImagePath, untrusted);
}

/// <summary>
/// Verifies a peer process's image and loaded modules with Authenticode plus a
/// trusted-directory allowlist.
/// </summary>
public sealed class PeerImageValidator
{
    private readonly IReadOnlyList<string> _trustedDirectories;

    /// <param name="trustedDirectories">Directories a module may load from
    /// (e.g. the install dir and <c>C:\Windows\System32</c>). A module outside
    /// all of them is rejected even if Authenticode passes, blocking a signed-but-
    /// planted DLL loaded from a writable path.</param>
    public PeerImageValidator(IReadOnlyList<string> trustedDirectories)
    {
        _trustedDirectories = trustedDirectories ?? throw new ArgumentNullException(nameof(trustedDirectories));
    }

    /// <summary>
    /// Validates the process with id <paramref name="processId"/>.
    /// </summary>
    public PeerImageVerdict Validate(uint processId)
    {
        using var process = Process.GetProcessById((int)processId);

        string mainImage = process.MainModule?.FileName
            ?? throw new InvalidOperationException($"Cannot read main module of PID {processId}.");

        var untrusted = new List<string>();

        if (!IsModuleTrusted(mainImage))
        {
            untrusted.Add(mainImage);
        }

        // R16: enumerate + verify EVERY loaded module, not just the image.
        foreach (ProcessModule module in process.Modules)
        {
            string path = module.FileName;
            if (!IsModuleTrusted(path))
            {
                untrusted.Add(path);
            }
        }

        return untrusted.Count == 0
            ? PeerImageVerdict.TrustedImage(mainImage)
            : PeerImageVerdict.Rejected(mainImage, untrusted);
    }

    private bool IsModuleTrusted(string modulePath)
    {
        return IsUnderTrustedDirectory(modulePath) && IsAuthenticodeTrusted(modulePath);
    }

    private bool IsUnderTrustedDirectory(string modulePath)
    {
        string full = System.IO.Path.GetFullPath(modulePath);
        foreach (string dir in _trustedDirectories)
        {
            // Normalize the root to end in a separator so a prefix match cannot
            // let "C:\Program FilesEvil\x.dll" pass the "C:\Program Files" allow.
            string root = System.IO.Path.GetFullPath(dir).TrimEnd(
                System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar);
            string rootWithSep = root + System.IO.Path.DirectorySeparatorChar;
            if (string.Equals(full, root, StringComparison.OrdinalIgnoreCase) ||
                full.StartsWith(rootWithSep, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Runs WinVerifyTrust (WINTRUST_ACTION_GENERIC_VERIFY_V2) over a file and
    /// returns whether the Authenticode signature chains to a trusted root.
    /// </summary>
    public static bool IsAuthenticodeTrusted(string filePath)
    {
        var fileInfo = new WINTRUST_FILE_INFO
        {
            cbStruct = (uint)Marshal.SizeOf<WINTRUST_FILE_INFO>(),
            pcwszFilePath = filePath,
            hFile = IntPtr.Zero,
            pgKnownSubject = IntPtr.Zero,
        };

        IntPtr pFile = Marshal.AllocHGlobal(Marshal.SizeOf<WINTRUST_FILE_INFO>());
        IntPtr pData = IntPtr.Zero;
        Guid action = NativeConstants.WINTRUST_ACTION_GENERIC_VERIFY_V2;
        try
        {
            Marshal.StructureToPtr(fileInfo, pFile, fDeleteOld: false);

            var data = new WINTRUST_DATA
            {
                cbStruct = (uint)Marshal.SizeOf<WINTRUST_DATA>(),
                dwUIChoice = NativeConstants.WTD_UI_NONE,
                fdwRevocationChecks = NativeConstants.WTD_REVOKE_NONE,
                dwUnionChoice = NativeConstants.WTD_CHOICE_FILE,
                pFile = pFile,
                dwStateAction = NativeConstants.WTD_STATEACTION_VERIFY,
            };

            pData = Marshal.AllocHGlobal(Marshal.SizeOf<WINTRUST_DATA>());
            Marshal.StructureToPtr(data, pData, fDeleteOld: false);

            int result = NativeMethods.WinVerifyTrust(IntPtr.Zero, ref action, pData);

            // Always release the WVT state, then report the verdict.
            data = Marshal.PtrToStructure<WINTRUST_DATA>(pData);
            data.dwStateAction = NativeConstants.WTD_STATEACTION_CLOSE;
            Marshal.StructureToPtr(data, pData, fDeleteOld: false);
            NativeMethods.WinVerifyTrust(IntPtr.Zero, ref action, pData);

            return result == NativeConstants.TRUST_S_OK;
        }
        finally
        {
            if (pData != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(pData);
            }

            Marshal.DestroyStructure<WINTRUST_FILE_INFO>(pFile);
            Marshal.FreeHGlobal(pFile);
        }
    }
}
