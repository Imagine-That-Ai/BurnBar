using System;
using System.Collections.ObjectModel;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.SessionLogs;
using Windows.ApplicationModel.DataTransfer;

namespace OpenBurnBar.App.SessionLogs;

/// <summary>
/// The session-log detail pane (Windows). Renders the selected <see cref="SessionLogRecord"/>
/// as a header + structured transcript (parsed by the portable
/// <see cref="TranscriptBlockParser"/>) + a Copy action. Header fields update in
/// code-behind on <see cref="Record"/> change; the transcript binds to
/// <see cref="Blocks"/> (an observable collection).
/// </summary>
public sealed partial class SessionLogDetailPane : UserControl
{
    private string _markdownBody = string.Empty;

    public SessionLogDetailPane()
    {
        InitializeComponent();
    }

    /// <summary>Parsed transcript blocks bound by the transcript <c>ListView</c>.</summary>
    public ObservableCollection<TranscriptBlock> Blocks { get; } = new();

    /// <summary>The record to display, or <c>null</c> for the empty state.</summary>
    public SessionLogRecord? Record
    {
        get => (SessionLogRecord?)GetValue(RecordProperty);
        set => SetValue(RecordProperty, value);
    }

    public static readonly DependencyProperty RecordProperty = DependencyProperty.Register(
        nameof(Record),
        typeof(SessionLogRecord),
        typeof(SessionLogDetailPane),
        new PropertyMetadata(null, OnRecordChanged));

    private static void OnRecordChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        ((SessionLogDetailPane)d).Render(e.NewValue as SessionLogRecord);
    }

    private void Render(SessionLogRecord? record)
    {
        Blocks.Clear();

        if (record is null)
        {
            EmptyState.Visibility = Visibility.Visible;
            ContentRoot.Visibility = Visibility.Collapsed;
            _markdownBody = string.Empty;
            return;
        }

        EmptyState.Visibility = Visibility.Collapsed;
        ContentRoot.Visibility = Visibility.Visible;

        bool isAssistant = record.SourceType == SessionLogSourceType.CliAssistant;
        SourceLabel.Text = isAssistant ? "Assistant" : record.ProviderDisplayName;
        SourceIcon.Glyph = isAssistant ? "" : "";
        ProjectLabel.Text = record.ProjectName;
        TimeLabel.Text = RelativeTime.Label(record.TimelineDate, DateTimeOffset.Now);
        TitleLabel.Text = record.DisplayTitle;
        MetaLabel.Text = BuildMeta(record);

        var parsed = TranscriptBlockParser.Parse(record.FullText);
        foreach (var block in parsed)
        {
            Blocks.Add(block);
        }

        bool hasBlocks = parsed.Count > 0;
        TranscriptList.Visibility = hasBlocks ? Visibility.Visible : Visibility.Collapsed;
        FallbackBody.Visibility = hasBlocks ? Visibility.Collapsed : Visibility.Visible;
        FallbackBody.Text = hasBlocks ? string.Empty : TranscriptBlockParser.StripSystemTags(record.FullText);

        _markdownBody = BuildMarkdown(record);
        CopyLabel.Text = "Copy Markdown";
        CopyButton.IsEnabled = _markdownBody.Length != 0;
    }

    private static string BuildMeta(SessionLogRecord record)
    {
        int words = record.UserWordCount + record.AssistantWordCount;
        string messages = $"{record.MessageCount} message{(record.MessageCount == 1 ? string.Empty : "s")}";
        return words > 0 ? $"{messages} · {words} words" : messages;
    }

    private static string BuildMarkdown(SessionLogRecord record)
    {
        var sb = new StringBuilder();
        sb.Append("# ").AppendLine(record.DisplayTitle);
        sb.AppendLine();
        sb.Append("- Provider: ").AppendLine(record.ProviderDisplayName);
        sb.Append("- Project: ").AppendLine(record.ProjectName);
        sb.Append("- Messages: ").AppendLine(record.MessageCount.ToString());
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine();
        sb.AppendLine(TranscriptBlockParser.StripSystemTags(record.FullText));
        return sb.ToString();
    }

    private void OnCopyMarkdownClick(object sender, RoutedEventArgs e)
    {
        if (_markdownBody.Length == 0)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(_markdownBody);
        Clipboard.SetContent(package);
        CopyLabel.Text = "Copied!";
    }
}
