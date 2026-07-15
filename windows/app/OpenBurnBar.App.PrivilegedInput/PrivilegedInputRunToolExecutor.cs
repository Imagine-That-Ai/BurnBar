using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.Loop;

namespace OpenBurnBar.App.PrivilegedInput;

/// <summary>
/// Production bridge from an approved durable agent tool call to the isolated
/// input broker. It records a redacted, tamper-evident reservation before the
/// native side effect and never returns input payloads to the run journal.
/// </summary>
public sealed class PrivilegedInputRunToolExecutor : IHeadlessAgentInternalToolExecutor
{
    public const int SessionActionCap = 50;
    public static readonly TimeSpan SessionTimeout = TimeSpan.FromMinutes(30);

    private readonly IPrivilegedInputDispatcher _dispatcher;
    private readonly string _auditRoot;
    private readonly string _userId;
    private readonly string _appVersion;
    private readonly Func<DateTimeOffset> _now;
    private readonly ConcurrentDictionary<string, SessionAuditState> _sessions = new(StringComparer.Ordinal);

    public PrivilegedInputRunToolExecutor(
        IPrivilegedInputDispatcher dispatcher,
        string auditRoot,
        string userId,
        string appVersion,
        Func<DateTimeOffset>? now = null)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _auditRoot = Path.GetFullPath(auditRoot ?? throw new ArgumentNullException(nameof(auditRoot)));
        _userId = RequireBounded(userId, 256, nameof(userId));
        _appVersion = RequireBounded(appVersion, 128, nameof(appVersion));
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public bool HasActiveSessions => !_sessions.IsEmpty;

    public bool CanExecute(BurnBarToolKind tool) => tool is
        BurnBarToolKind.MacInputClick
        or BurnBarToolKind.MacInputType
        or BurnBarToolKind.MacInputKey
        or BurnBarToolKind.MacInputShortcut
        or BurnBarToolKind.MacInputDragDrop
        or BurnBarToolKind.MacInputScroll
        or BurnBarToolKind.MacInputPointerMove;

    public async Task<HeadlessAgentInternalToolExecutionResult> ExecuteAsync(
        string sessionId,
        HeadlessAgentToolCall call,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(call);
        string normalizedSessionId = NormalizeSessionId(sessionId);
        if (!CanExecute(call.Tool))
        {
            return Failure(BurnBarToolExecutionErrorCode.RemoteUnsupported, "The tool is not a desktop-input action.");
        }
        if (string.IsNullOrWhiteSpace(call.ApprovalId))
        {
            return Failure(BurnBarToolExecutionErrorCode.TrustGated, "The desktop-input approval is missing.");
        }

        MacInputAction action;
        try
        {
            action = ParseAction(call.Tool, call.Arguments);
        }
        catch (ArgumentException)
        {
            return Failure(BurnBarToolExecutionErrorCode.Unknown, "The desktop-input arguments are invalid.");
        }

        SessionAuditState state;
        try
        {
            state = _sessions.GetOrAdd(normalizedSessionId, CreateSessionState);
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException
            or InvalidDataException
            or JsonException
            or ComputerUseAuditLogger.AuditLoggerException)
        {
            return Failure(BurnBarToolExecutionErrorCode.TrustGated, "The Computer Use audit archive is unavailable.");
        }

        await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            DateTimeOffset now = _now();
            if (now - state.StartedAt >= SessionTimeout
                || state.Logger.NextEntryIndex >= SessionActionCap)
            {
                AppendAudit(
                    state.Logger,
                    action,
                    now,
                    AuditApprovedBy.Denied,
                    call.ApprovalId,
                    ComputerUseDenyReason.SessionLimit.ToWire());
                return Failure(BurnBarToolExecutionErrorCode.TrustGated, "The Computer Use session limit was reached.");
            }

            AppendAudit(
                state.Logger,
                action,
                now,
                AuditApprovedBy.Mac,
                call.ApprovalId,
                denyReason: null);

            PrivilegedInputResponse response;
            try
            {
                response = await _dispatcher.DispatchAsync(
                    normalizedSessionId,
                    call.ApprovalId,
                    call.CallId,
                    action,
                    cancellationToken: cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException
                or InvalidOperationException
                or TimeoutException)
            {
                response = new PrivilegedInputResponse(false, "broker_unavailable");
            }

            if (!response.Ok)
            {
                AppendAudit(
                    state.Logger,
                    action,
                    _now(),
                    AuditApprovedBy.Denied,
                    call.ApprovalId,
                    NormalizeDetail(response.Detail));
                return Failure(
                    response.Detail is "kill_switch" or "protected_target"
                        ? BurnBarToolExecutionErrorCode.TrustGated
                        : BurnBarToolExecutionErrorCode.Unknown,
                    "The protected desktop-input action was denied.");
            }

            JsonElement output = JsonSerializer.SerializeToElement(new
            {
                actionKind = action.AuditKind,
                status = "dispatched",
                auditHead = state.Logger.HeadHashHex,
            });
            return new HeadlessAgentInternalToolExecutionResult(true, output);
        }
        catch (Exception error) when (error is IOException
            or UnauthorizedAccessException
            or ComputerUseAuditLogger.AuditLoggerException)
        {
            return Failure(BurnBarToolExecutionErrorCode.TrustGated, "The Computer Use audit reservation failed.");
        }
        finally
        {
            state.Gate.Release();
        }
    }

    public async Task RecordPanicAsync(
        ComputerUsePanicSource source,
        CancellationToken cancellationToken = default)
    {
        var action = new PhoneControlIntent(PhoneControlIntent.Kind.Panic);
        foreach (SessionAuditState state in _sessions.Values)
        {
            await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                AppendAudit(
                    state.Logger,
                    action,
                    _now(),
                    AuditApprovedBy.Panic,
                    approvalId: null,
                    denyReason: source.ToWire());
            }
            finally
            {
                state.Gate.Release();
            }
        }
    }

    private SessionAuditState CreateSessionState(string sessionId)
    {
        Directory.CreateDirectory(_auditRoot);
        EnsureNotReparsePoint(new DirectoryInfo(_auditRoot));
        string root = _auditRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string sessionDirectory = Path.GetFullPath(Path.Combine(_auditRoot, sessionId));
        if (!sessionDirectory.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("The Computer Use audit path escapes its root.");
        }

        bool existing = File.Exists(Path.Combine(sessionDirectory, "manifest.json"));
        if (!existing
            && Directory.Exists(sessionDirectory)
            && Directory.EnumerateFileSystemEntries(sessionDirectory).Any())
        {
            throw new InvalidDataException("The Computer Use audit session is incomplete or untrusted.");
        }
        var logger = new ComputerUseAuditLogger(sessionId, _auditRoot, _appVersion);
        EnsureNotReparsePoint(new DirectoryInfo(sessionDirectory));
        EnsureNotReparsePoint(new DirectoryInfo(Path.Combine(sessionDirectory, "screenshots")));
        DateTimeOffset startedAt;
        if (existing)
        {
            logger.ResumeExistingSession();
            startedAt = ReadStartedAt(Path.Combine(sessionDirectory, "manifest.json"));
            if (startedAt > _now().AddMinutes(5))
            {
                throw new InvalidDataException("The Computer Use manifest start time is invalid.");
            }
        }
        else
        {
            startedAt = _now();
            logger.BeginSession(new ComputerUseSessionManifest(
                sessionId,
                ComputerUseMode.System,
                ComputerUseTrustMode.Manual,
                startedAt,
                _userId,
                "approved_local_agent_run",
                SessionActionCap,
                checked((int)SessionTimeout.TotalSeconds)));
        }
        return new SessionAuditState(logger, startedAt);
    }

    private static MacInputAction ParseAction(BurnBarToolKind tool, JsonElement arguments)
    {
        if (arguments.ValueKind != JsonValueKind.Object)
        {
            throw new ArgumentException("Input arguments must be an object.", nameof(arguments));
        }
        return tool switch
        {
            BurnBarToolKind.MacInputClick => new MacInputAction(
                MacInputAction.Kind.Click,
                RequiredInt(arguments, "displayX", "x"),
                RequiredInt(arguments, "displayY", "y"),
                mouseButton: OptionalInt(arguments, "mouseButton") ?? 0),
            BurnBarToolKind.MacInputType => new MacInputAction(
                MacInputAction.Kind.Type,
                text: RequiredString(arguments, "text", PrivilegedInputCommand.MaximumTextCharacters)),
            BurnBarToolKind.MacInputKey => new MacInputAction(
                MacInputAction.Kind.Key,
                key: RequiredString(arguments, "key", 64)),
            BurnBarToolKind.MacInputShortcut => new MacInputAction(
                MacInputAction.Kind.Shortcut,
                key: RequiredString(arguments, "key", 64),
                modifiers: RequiredStrings(arguments, "modifiers", 8, 16)),
            BurnBarToolKind.MacInputDragDrop => new MacInputAction(
                MacInputAction.Kind.DragDrop,
                RequiredInt(arguments, "displayX", "startX"),
                RequiredInt(arguments, "displayY", "startY"),
                RequiredInt(arguments, "dragEndX", "endX"),
                RequiredInt(arguments, "dragEndY", "endY"),
                mouseButton: OptionalInt(arguments, "mouseButton") ?? 0),
            BurnBarToolKind.MacInputScroll => new MacInputAction(
                MacInputAction.Kind.Scroll,
                OptionalInt(arguments, "displayX"),
                OptionalInt(arguments, "displayY"),
                deltaX: OptionalInt(arguments, "deltaX") ?? 0,
                deltaY: OptionalInt(arguments, "deltaY") ?? 0),
            BurnBarToolKind.MacInputPointerMove => new MacInputAction(
                MacInputAction.Kind.PointerMove,
                RequiredInt(arguments, "displayX", "x"),
                RequiredInt(arguments, "displayY", "y")),
            _ => throw new ArgumentException("Unsupported desktop-input tool.", nameof(tool)),
        };
    }

    private static int RequiredInt(JsonElement owner, string primary, string alternate)
    {
        JsonElement value;
        if ((!owner.TryGetProperty(primary, out value) && !owner.TryGetProperty(alternate, out value))
            || value.ValueKind != JsonValueKind.Number
            || !value.TryGetInt32(out int result))
        {
            throw new ArgumentException($"{primary} is required.");
        }
        return result;
    }

    private static int? OptionalInt(JsonElement owner, string name) =>
        !owner.TryGetProperty(name, out JsonElement value) || value.ValueKind == JsonValueKind.Null
            ? null
            : value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int result)
                ? result
                : throw new ArgumentException($"{name} must be an integer.");

    private static string RequiredString(JsonElement owner, string name, int maximumLength)
    {
        if (!owner.TryGetProperty(name, out JsonElement value)
            || value.ValueKind != JsonValueKind.String
            || value.GetString() is not string text
            || text.Length is 0 || text.Length > maximumLength)
        {
            throw new ArgumentException($"{name} is required.");
        }
        return text;
    }

    private static IReadOnlyList<string> RequiredStrings(
        JsonElement owner,
        string name,
        int maximumCount,
        int maximumLength)
    {
        if (!owner.TryGetProperty(name, out JsonElement value)
            || value.ValueKind != JsonValueKind.Array
            || value.GetArrayLength() is 0 || value.GetArrayLength() > maximumCount)
        {
            throw new ArgumentException($"{name} is required.");
        }
        string[] result = value.EnumerateArray().Select(item =>
        {
            if (item.ValueKind != JsonValueKind.String
                || item.GetString() is not string text
                || text.Length is 0 || text.Length > maximumLength)
            {
                throw new ArgumentException($"{name} contains an invalid value.");
            }
            return text;
        }).ToArray();
        return result;
    }

    private static DateTimeOffset ReadStartedAt(string manifestPath)
    {
        var info = new FileInfo(manifestPath);
        EnsureNotReparsePoint(info);
        if (info.Length is <= 0 or > 256 * 1024)
        {
            throw new InvalidDataException("The Computer Use manifest is invalid.");
        }
        byte[] payload;
        using (var stream = new FileStream(manifestPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (stream.Length is <= 0 or > 256 * 1024)
            {
                throw new InvalidDataException("The Computer Use manifest is invalid.");
            }
            payload = new byte[checked((int)stream.Length)];
            stream.ReadExactly(payload);
            if (stream.ReadByte() != -1)
            {
                throw new InvalidDataException("The Computer Use manifest changed while it was read.");
            }
        }
        using JsonDocument document = JsonDocument.Parse(payload);
        if (!document.RootElement.TryGetProperty("startedAt", out JsonElement value)
            || value.ValueKind != JsonValueKind.Number
            || !value.TryGetInt64(out long milliseconds))
        {
            throw new InvalidDataException("The Computer Use manifest start time is missing.");
        }
        try
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        }
        catch (ArgumentOutOfRangeException error)
        {
            throw new InvalidDataException("The Computer Use manifest start time is invalid.", error);
        }
    }

    private static void AppendAudit(
        ComputerUseAuditLogger logger,
        ComputerUseAction action,
        DateTimeOffset timestamp,
        AuditApprovedBy approvedBy,
        string? approvalId,
        string? denyReason)
    {
        ComputerUseAuditEntry entry = logger.MakeEntry(
            action,
            timestamp,
            approvedBy,
            approvalId: approvalId,
            denyReason: denyReason);
        logger.Append(entry);
    }

    private static HeadlessAgentInternalToolExecutionResult Failure(
        BurnBarToolExecutionErrorCode code,
        string message) =>
        new(false, Error: new HeadlessAgentToolError(code, message));

    private static string NormalizeSessionId(string sessionId)
    {
        string value = RequireBounded(sessionId, 128, nameof(sessionId));
        if (value is "." or ".." || value.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.')))
        {
            throw new ArgumentException("The Computer Use session id is invalid.", nameof(sessionId));
        }
        return value;
    }

    private static string RequireBounded(string value, int maximumLength, string parameterName)
    {
        string normalized = value?.Trim() ?? string.Empty;
        if (normalized.Length is 0 || normalized.Length > maximumLength || normalized.Any(char.IsControl))
        {
            throw new ArgumentException("A bounded value is required.", parameterName);
        }
        return normalized;
    }

    private static string NormalizeDetail(string detail)
    {
        string value = detail.Trim();
        return value.Length is > 0 and <= 64 && value.All(character =>
            char.IsAsciiLetterOrDigit(character) || character is '_' or '-')
                ? value
                : "dispatch_failed";
    }

    private static void EnsureNotReparsePoint(FileSystemInfo info)
    {
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException("The Computer Use audit path is unavailable.");
        }
    }

    private sealed class SessionAuditState
    {
        public SessionAuditState(ComputerUseAuditLogger logger, DateTimeOffset startedAt)
        {
            Logger = logger;
            StartedAt = startedAt;
        }

        public ComputerUseAuditLogger Logger { get; }
        public DateTimeOffset StartedAt { get; }
        public SemaphoreSlim Gate { get; } = new(1, 1);
    }
}
