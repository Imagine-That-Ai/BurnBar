using System;
using System.Collections.Specialized;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Pretext;
using OpenBurnBar.Pretext;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.System;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Code-behind for the Chat surface. Owns the <see cref="ChatSurfaceViewModel"/>,
/// boots the offscreen WebView2 Pretext host so the streaming bubbles measure
/// against the real engine (dev-host-deferred on non-Windows), auto-scrolls to the
/// newest message, and sends on Enter.
/// </summary>
public sealed partial class ChatSurfaceView : UserControl
{
    private PretextEngine? _engine;
    private WebView2PretextHost? _host;
    private WebView2? _webView;

    public ChatSurfaceView()
    {
        InitializeComponent();
        ViewModel = new ChatSurfaceViewModel();
        ViewModel.Messages.CollectionChanged += OnMessagesChanged;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    public ChatSurfaceViewModel ViewModel { get; }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await InitializePretextAsync().ConfigureAwait(true);
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        // Detach the shared engine so recycled bubbles do not hold a stale host.
        if (ReferenceEquals(ChatPretextEngineHost.Current, _engine))
        {
            ChatPretextEngineHost.Current = null;
        }
        _engine?.Dispose();
        _host?.Dispose();
        if (_webView is not null)
        {
            PretextHost.Children.Remove(_webView);
            _webView = null;
        }
        _engine = null;
        _host = null;
    }

    private async Task InitializePretextAsync()
    {
        if (_engine is not null)
        {
            return;
        }
        if (!NativeCapability.IsWebView2Enabled(out _))
        {
            return;
        }

        try
        {
            _webView = new WebView2
            {
                Width = 0,
                Height = 0,
                Visibility = Visibility.Collapsed,
                IsHitTestVisible = false,
            };
            PretextHost.Children.Add(_webView);
            _host = new WebView2PretextHost(_webView);
            _engine = new PretextEngine(_host);
            await _engine.StartAsync().ConfigureAwait(true);
            ViewModel.PretextEngine = _engine;
            ChatPretextEngineHost.Current = _engine;
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("chat.pretext", ex);
            // Measurement host unavailable (no WebView2 runtime): the bubbles keep
            // their inline fallback layout. Never blocks the surface.
            _engine = null;
            _host = null;
            if (_webView is not null)
            {
                PretextHost.Children.Remove(_webView);
                _webView = null;
            }
        }
    }

    private void OnMessagesChanged(object? sender, NotifyCollectionChangedEventArgs args)
    {
        // Keep the newest turn in view as it streams in.
        DispatcherQueue.TryEnqueue(() => MessageScroller.ChangeView(null, MessageScroller.ScrollableHeight, null));
    }

    private void OnInputKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter
            && !e.KeyStatus.IsMenuKeyDown
            && ViewModel.SendCommand.CanExecute(null))
        {
            e.Handled = true;
            ViewModel.SendCommand.Execute(null);
        }
    }

    private void OnInputDragOver(object sender, DragEventArgs e)
    {
        DataPackageView data = e.DataView;
        if (data.Contains(StandardDataFormats.StorageItems) || data.Contains(StandardDataFormats.Text))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
        }
    }

    private async void OnInputDrop(object sender, DragEventArgs e)
    {
        try
        {
            bool staged = await TryStageDataPackageAsync(e.DataView, stageShortText: true).ConfigureAwait(true);
            e.Handled = staged;
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("chat.attachment.drop", ex);
        }
    }

    private async void OnInputPaste(object sender, TextControlPasteEventArgs e)
    {
        try
        {
            bool staged = await TryStageDataPackageAsync(Clipboard.GetContent(), stageShortText: false).ConfigureAwait(true);
            e.Handled = staged;
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("chat.attachment.paste", ex);
        }
    }

    private async Task<bool> TryStageDataPackageAsync(DataPackageView data, bool stageShortText)
    {
        if (data.Contains(StandardDataFormats.StorageItems))
        {
            var items = await data.GetStorageItemsAsync().AsTask().ConfigureAwait(true);
            var staged = false;
            foreach (IStorageItem item in items.OfType<StorageFile>())
            {
                if (!string.IsNullOrWhiteSpace(item.Path))
                {
                    ViewModel.StageAttachmentFromFile(item.Path);
                    staged = true;
                }
            }

            if (staged)
            {
                return true;
            }
        }

        if (!data.Contains(StandardDataFormats.Text))
        {
            return false;
        }

        string text = await data.GetTextAsync().AsTask().ConfigureAwait(true);
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }

        if (!stageShortText && Encoding.UTF8.GetByteCount(text) <= WindowsChatAttachmentStager.TextPreviewBytes)
        {
            return false;
        }

        ViewModel.StagePastedText(text);
        return true;
    }
}
