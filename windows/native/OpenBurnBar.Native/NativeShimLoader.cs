using System;
using System.Collections.Concurrent;
using System.Reflection;
using System.Runtime.InteropServices;

namespace OpenBurnBar.Native;

/// <summary>
/// Registers the hardened <see cref="NativeLibraryLocator"/> as the
/// DllImport resolver for a generated uniffi binding assembly, and answers
/// availability probes without ever throwing.
///
/// Each per-crate shim calls <see cref="RegisterResolver"/> once (idempotent)
/// for its binding assembly + logical library name. From then on every
/// generated <c>DllImport("&lt;logicalName&gt;")</c> in that assembly resolves
/// through the locator's absolute-path probe instead of the platform loader's
/// default search — and resolution failure surfaces as the caller's
/// <see cref="NativeShimUnavailableException"/> rather than a path-dependent
/// <see cref="DllNotFoundException"/>.
/// </summary>
public static class NativeShimLoader
{
    // assembly -> logical names routed through the locator for that assembly.
    private static readonly ConcurrentDictionary<Assembly, ConcurrentDictionary<string, byte>> Registrations = new();

    // logical name -> cached OS handle (a cdylib is loaded at most once).
    private static readonly ConcurrentDictionary<string, IntPtr> Handles = new();

    /// <summary>Routes <paramref name="logicalName"/> DllImports declared in
    /// <paramref name="bindingAssembly"/> through the hardened locator.
    /// Idempotent per (assembly, name); multiple logical names may share one
    /// assembly.</summary>
    public static void RegisterResolver(Assembly bindingAssembly, string logicalName)
    {
        ArgumentNullException.ThrowIfNull(bindingAssembly);
        if (string.IsNullOrWhiteSpace(logicalName))
        {
            throw new ArgumentException("logical library name must be non-empty", nameof(logicalName));
        }

        bool firstForAssembly = false;
        var names = Registrations.GetOrAdd(bindingAssembly, _ =>
        {
            firstForAssembly = true;
            return new ConcurrentDictionary<string, byte>(StringComparer.Ordinal);
        });
        names.TryAdd(logicalName, 0);

        if (firstForAssembly)
        {
            // SetDllImportResolver throws on a second registration for the same
            // assembly, so it is set exactly once and consults the name table.
            NativeLibrary.SetDllImportResolver(bindingAssembly, Resolve);
        }
    }

    /// <summary>True when the cdylib either is already loaded or is present in
    /// the hardened probe directories. Never throws.</summary>
    public static bool IsAvailable(string logicalName)
    {
        if (Handles.TryGetValue(logicalName, out var cached) && cached != IntPtr.Zero)
        {
            return true;
        }

        return NativeLibraryLocator.Locate(logicalName) is not null;
    }

    /// <summary>Throws the shim's graceful NotSupported error when the cdylib
    /// is absent. Facades call this at every public entry point.</summary>
    public static void ThrowIfUnavailable(string logicalName, string shimDescription)
    {
        if (!IsAvailable(logicalName))
        {
            throw new NativeShimUnavailableException(logicalName, shimDescription);
        }
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!Registrations.TryGetValue(assembly, out var names) || !names.ContainsKey(libraryName))
        {
            return IntPtr.Zero; // not ours — fall back to the default resolver
        }

        return Handles.GetOrAdd(libraryName, static name =>
        {
            string? path = NativeLibraryLocator.Locate(name);
            return path is not null && NativeLibrary.TryLoad(path, out var handle)
                ? handle
                : IntPtr.Zero;
        });
    }
}
