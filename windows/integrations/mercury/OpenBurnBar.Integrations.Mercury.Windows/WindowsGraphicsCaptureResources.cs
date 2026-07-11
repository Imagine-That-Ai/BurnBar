using System;
using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace OpenBurnBar.Integrations.Mercury.Windows;

internal static class WindowsGraphicsCaptureResources
{
    private const uint D3D11CreateDeviceBgraSupport = 0x20;
    private const int D3DDriverTypeHardware = 1;
    private const int D3DDriverTypeWarp = 5;
    private const uint D3D11SdkVersion = 7;
    private const string GraphicsCaptureItemRuntimeClass = "Windows.Graphics.Capture.GraphicsCaptureItem";

    private static readonly Guid GraphicsCaptureItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    private static readonly Guid GraphicsCaptureItemInteropIid = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    private static readonly Guid DxgiDeviceIid = new("54EC77FA-1377-44E6-8C32-88FD5F44C84C");

    public static GraphicsCaptureItem CreateItemForWindow(IntPtr window)
    {
        if (window == IntPtr.Zero)
        {
            throw new ArgumentException("Window handle must be non-zero.", nameof(window));
        }

        IntPtr className = IntPtr.Zero;
        IntPtr factoryPointer = IntPtr.Zero;
        IntPtr itemPointer = IntPtr.Zero;
        try
        {
            Marshal.ThrowExceptionForHR(WindowsCreateString(
                GraphicsCaptureItemRuntimeClass,
                GraphicsCaptureItemRuntimeClass.Length,
                out className));
            Guid factoryIid = GraphicsCaptureItemInteropIid;
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(className, ref factoryIid, out factoryPointer));
            var factory = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(factoryPointer);
            Guid itemIid = GraphicsCaptureItemIid;
            Marshal.ThrowExceptionForHR(factory.CreateForWindow(window, ref itemIid, out itemPointer));
            return MarshalInterface<GraphicsCaptureItem>.FromAbi(itemPointer);
        }
        finally
        {
            Release(ref itemPointer);
            Release(ref factoryPointer);
            if (className != IntPtr.Zero)
            {
                WindowsDeleteString(className);
            }
        }
    }

    public static IDirect3DDevice CreateDirect3DDevice()
    {
        IntPtr d3dDevice = IntPtr.Zero;
        IntPtr context = IntPtr.Zero;
        IntPtr dxgiDevice = IntPtr.Zero;
        IntPtr inspectable = IntPtr.Zero;
        try
        {
            int result = D3D11CreateDevice(
                IntPtr.Zero,
                D3DDriverTypeHardware,
                IntPtr.Zero,
                D3D11CreateDeviceBgraSupport,
                IntPtr.Zero,
                0,
                D3D11SdkVersion,
                out d3dDevice,
                out _,
                out context);
            if (result < 0)
            {
                Release(ref d3dDevice);
                Release(ref context);
                Marshal.ThrowExceptionForHR(D3D11CreateDevice(
                    IntPtr.Zero,
                    D3DDriverTypeWarp,
                    IntPtr.Zero,
                    D3D11CreateDeviceBgraSupport,
                    IntPtr.Zero,
                    0,
                    D3D11SdkVersion,
                    out d3dDevice,
                    out _,
                    out context));
            }

            Guid dxgiDeviceIid = DxgiDeviceIid;
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(d3dDevice, in dxgiDeviceIid, out dxgiDevice));
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, out inspectable));
            return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
        }
        finally
        {
            Release(ref inspectable);
            Release(ref dxgiDevice);
            Release(ref context);
            Release(ref d3dDevice);
        }
    }

    private static void Release(ref IntPtr pointer)
    {
        if (pointer == IntPtr.Zero)
        {
            return;
        }

        Marshal.Release(pointer);
        pointer = IntPtr.Zero;
    }

    [ComImport]
    [Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        [PreserveSig]
        int CreateForWindow(IntPtr window, ref Guid iid, out IntPtr result);

        [PreserveSig]
        int CreateForMonitor(IntPtr monitor, ref Guid iid, out IntPtr result);
    }

    [DllImport("combase.dll", CharSet = CharSet.Unicode)]
    private static extern int WindowsCreateString(string source, int length, out IntPtr value);

    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr value);

    [DllImport("combase.dll")]
    private static extern int RoGetActivationFactory(IntPtr className, ref Guid iid, out IntPtr factory);

    [DllImport("d3d11.dll")]
    private static extern int D3D11CreateDevice(
        IntPtr adapter,
        int driverType,
        IntPtr software,
        uint flags,
        IntPtr featureLevels,
        uint featureLevelCount,
        uint sdkVersion,
        out IntPtr device,
        out int featureLevel,
        out IntPtr immediateContext);

    [DllImport("d3d11.dll")]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
}
