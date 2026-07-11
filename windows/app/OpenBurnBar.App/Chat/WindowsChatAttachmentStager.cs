using System;
using System.IO;
using System.Linq;
using System.Text;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

public static class WindowsChatAttachmentStager
{
    public const long MaxTextDocumentBytes = 2 * 1024 * 1024;
    public const long MaxGenericBytes = 200 * 1024 * 1024;
    public const int TextPreviewBytes = 4 * 1024;

    public static ChatAttachmentRecord ImportFile(string sourcePath, string workspaceRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(workspaceRoot);
        if (!File.Exists(sourcePath))
        {
            throw new FileNotFoundException("Attachment file is missing.", sourcePath);
        }

        var info = new FileInfo(sourcePath);
        string kind = InferKind(info.Extension);
        long limit = kind == "textDocument" ? MaxTextDocumentBytes : MaxGenericBytes;
        if (info.Length > limit)
        {
            throw new InvalidOperationException("Attachment exceeds the Windows chat size limit.");
        }

        string id = Guid.NewGuid().ToString();
        string displayName = info.Name;
        string relativePath = "attachments/" + id + "-" + SafeFileName(displayName);
        string target = Path.Combine(workspaceRoot, relativePath.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        File.Copy(sourcePath, target, overwrite: false);

        return new ChatAttachmentRecord(
            id,
            kind,
            displayName,
            MimeTypeFor(kind, info.Extension),
            info.Length,
            relativePath,
            kind == "textDocument" ? ReadPreview(target) : null);
    }

    public static ChatAttachmentRecord ImportPastedText(string text, string workspaceRoot, string? suggestedName = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentException.ThrowIfNullOrWhiteSpace(workspaceRoot);
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        if (bytes.LongLength > MaxTextDocumentBytes)
        {
            throw new InvalidOperationException("Pasted text exceeds the Windows chat size limit.");
        }

        string id = Guid.NewGuid().ToString();
        string displayName = string.IsNullOrWhiteSpace(suggestedName) ? "pasted-text.txt" : suggestedName.Trim();
        string relativePath = "attachments/" + id + "-" + SafeFileName(displayName);
        string target = Path.Combine(workspaceRoot, relativePath.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        File.WriteAllBytes(target, bytes);

        return new ChatAttachmentRecord(
            id,
            "textDocument",
            displayName,
            "text/plain",
            bytes.LongLength,
            relativePath,
            text.Length <= TextPreviewBytes ? text : text[..TextPreviewBytes]);
    }

    public static ChatAttachmentRecord MarkMissingIfAbsent(ChatAttachmentRecord attachment, string workspaceRoot)
    {
        string target = Path.Combine(workspaceRoot, attachment.WorkspaceRelativePath.Replace('/', Path.DirectorySeparatorChar));
        return File.Exists(target)
            ? attachment
            : attachment with { IsMissing = true };
    }

    private static string SafeFileName(string name)
    {
        char[] safe = name
            .Select(ch => char.IsLetterOrDigit(ch) || ch is '.' or '_' or '-' ? ch : '_')
            .Take(80)
            .ToArray();
        return safe.Length == 0 ? "file" : new string(safe);
    }

    private static string InferKind(string extension)
    {
        string ext = extension.TrimStart('.').ToLowerInvariant();
        return ext switch
        {
            "txt" or "md" or "markdown" or "log" or "json" or "csv" or "yaml" or "yml" or "xml" or "cs" or "swift" or "kt" or "js" or "ts" => "textDocument",
            "png" or "jpg" or "jpeg" or "gif" or "webp" or "heic" => "image",
            "pdf" => "pdf",
            "mp3" or "m4a" or "wav" or "aiff" => "audio",
            "mov" or "mp4" => "video",
            _ => "generic",
        };
    }

    private static string MimeTypeFor(string kind, string extension)
    {
        return kind switch
        {
            "textDocument" => "text/plain",
            "image" => "image/" + extension.TrimStart('.').ToLowerInvariant().Replace("jpg", "jpeg", StringComparison.Ordinal),
            "pdf" => "application/pdf",
            "audio" => "audio/" + extension.TrimStart('.').ToLowerInvariant(),
            "video" => "video/" + extension.TrimStart('.').ToLowerInvariant(),
            _ => "application/octet-stream",
        };
    }

    private static string? ReadPreview(string path)
    {
        byte[] head = File.ReadAllBytes(path).Take(TextPreviewBytes).ToArray();
        return Encoding.UTF8.GetString(head).TrimStart('\uFEFF');
    }
}
