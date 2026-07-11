// IUiInspector over the IUIAutomation COM interface (read-only).
//
// Hand-written COM interop for the two UIA interfaces the inspector needs, with
// the exact vtable ordering from UIAutomationCore.h so the calls bind correctly
// on a Windows dev host. Only the methods actually invoked carry full
// signatures; the preceding vtable slots are declared as placeholders so the
// slot indices line up.
//
// The inspector answers the deny-region question the capability gate depends on:
// is the click target a password field / secure-desktop sheet / credential
// prompt? That classification (UiElementInfo.ClassifyDenyRegion) is the Windows
// analog of the macOS AX secure-field probe.
//
// Windows-only at runtime (COM + UIA). Roslyn-compiles on the macOS authoring
// host; the live probe is a Windows dev-host task.

using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Windows.Interop;

namespace OpenBurnBar.ComputerUse.Windows;

/// <summary>UIA-backed read-only inspector.</summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class UiaInspector : IUiInspector
{
    // UIA property ids (UIAutomationClient.h).
    private const int UiaProcessIdPropertyId = 30002;
    private const int UiaClassNamePropertyId = 30012;
    private const int UiaIsPasswordPropertyId = 30019;
    private const int UiaNamePropertyId = 30005;

    private static readonly Guid CuiAutomationClsid = new("ff48dba4-60ef-4201-aa87-54103eef594e");

    private readonly IUIAutomation _automation;

    public UiaInspector()
    {
        var type = Type.GetTypeFromCLSID(CuiAutomationClsid, throwOnError: true)!;
        _automation = (IUIAutomation)Activator.CreateInstance(type)!;
    }

    public UiElementInfo InspectPoint(int displayX, int displayY)
    {
        var point = new NativeMethods.POINT { X = displayX, Y = displayY };
        Marshal.ThrowExceptionForHR(_automation.ElementFromPoint(point, out var element));
        return Describe(element);
    }

    public UiElementInfo InspectFrontmost()
    {
        var hwnd = NativeMethods.GetForegroundWindow();
        return InspectWindow(hwnd);
    }

    public UiElementInfo InspectWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            throw new ArgumentException("Window handle must be non-zero.", nameof(hwnd));
        }

        Marshal.ThrowExceptionForHR(_automation.ElementFromHandle(hwnd, out var element));
        return Describe(element);
    }

    private static UiElementInfo Describe(IUIAutomationElement? element)
    {
        if (element is null)
        {
            return new UiElementInfo(null, null, false, false, false);
        }

        var isPassword = GetBool(element, UiaIsPasswordPropertyId);
        var name = GetString(element, UiaNamePropertyId);
        var className = GetString(element, UiaClassNamePropertyId);
        var processImage = ProcessImageName(element);

        // Secure-desktop / UAC surfaces surface as the LogonUI/consent processes;
        // credential prompts surface as CredentialUIBroker. Classify by process +
        // class so a click there is refused even when the rule set would allow it.
        var isSecureDesktop = EqualsAny(processImage, "LogonUI.exe", "consent.exe")
            || EqualsAny(className, "Credential Dialog Xaml Host");
        var isCredentialPrompt = EqualsAny(processImage, "CredentialUIBroker.exe", "credwiz.exe");

        return new UiElementInfo(processImage, name, isPassword, isSecureDesktop, isCredentialPrompt);
    }

    private static bool GetBool(IUIAutomationElement element, int propertyId)
    {
        Marshal.ThrowExceptionForHR(element.GetCurrentPropertyValue(propertyId, out var value));
        return value is bool b && b;
    }

    private static string? GetString(IUIAutomationElement element, int propertyId)
    {
        Marshal.ThrowExceptionForHR(element.GetCurrentPropertyValue(propertyId, out var value));
        return value as string;
    }

    private static string? ProcessImageName(IUIAutomationElement element)
    {
        if (element.GetCurrentPropertyValue(UiaProcessIdPropertyId, out var value) != 0 || value is not int pid)
        {
            return null;
        }

        try
        {
            using var process = Process.GetProcessById(pid);
            var name = process.ProcessName;
            return string.IsNullOrEmpty(name) ? null : name + ".exe";
        }
        catch (ArgumentException)
        {
            return null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private static bool EqualsAny(string? value, params string[] candidates)
    {
        if (value is null)
        {
            return false;
        }

        foreach (var candidate in candidates)
        {
            if (string.Equals(value, candidate, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}

/// <summary>The subset of IUIAutomation the inspector calls (vtable-ordered).</summary>
[ComImport]
[Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IUIAutomation
{
    [PreserveSig] int CompareElements();       // vtbl[3]
    [PreserveSig] int CompareRuntimeIds();     // vtbl[4]
    [PreserveSig] int GetRootElement();        // vtbl[5]

    [PreserveSig]
    int ElementFromHandle(IntPtr hwnd, [MarshalAs(UnmanagedType.Interface)] out IUIAutomationElement element); // vtbl[6]

    [PreserveSig]
    int ElementFromPoint(NativeMethods.POINT point, [MarshalAs(UnmanagedType.Interface)] out IUIAutomationElement element); // vtbl[7]
}

/// <summary>The subset of IUIAutomationElement the inspector calls (vtable-ordered).</summary>
[ComImport]
[Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IUIAutomationElement
{
    [PreserveSig] int SetFocus();               // vtbl[3]
    [PreserveSig] int GetRuntimeId();           // vtbl[4]
    [PreserveSig] int FindFirst();              // vtbl[5]
    [PreserveSig] int FindAll();                // vtbl[6]
    [PreserveSig] int FindFirstBuildCache();    // vtbl[7]
    [PreserveSig] int FindAllBuildCache();      // vtbl[8]
    [PreserveSig] int BuildUpdatedCache();      // vtbl[9]

    [PreserveSig]
    int GetCurrentPropertyValue(int propertyId, [MarshalAs(UnmanagedType.Struct)] out object value); // vtbl[10]
}
