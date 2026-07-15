using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Mission;

/// <summary>
/// Authenticated companion-plane adapter that lets local Mission Control and
/// agent workflows create followups/questions consumed by the Telegram bridge.
/// </summary>
public sealed class CompanionCliTelegramHandler
{
    private readonly TelegramMissionCommandHandler _handler;

    public CompanionCliTelegramHandler(TelegramMissionCommandHandler handler)
    {
        _handler = handler ?? throw new ArgumentNullException(nameof(handler));
    }

    public async Task<object?> RecordFollowupAsync(
        JsonElement request,
        CancellationToken cancellationToken)
    {
        var followup = new TelegramFollowup(
            RequiredString(request, "id", 128),
            RequiredString(request, "projectSlug", 128),
            RequiredString(request, "title", 512),
            RequiredString(request, "summary", 4096),
            OptionalBoolean(request, "isDone") ?? false,
            OptionalTimestamp(request, "snoozeUntil"),
            OptionalTimestamp(request, "nextNudgeAt"));
        await _handler.RecordFollowupAsync(followup, cancellationToken).ConfigureAwait(false);
        return new { followupId = followup.Id, recorded = true };
    }

    public async Task<object?> RecordQuestionAsync(
        JsonElement request,
        CancellationToken cancellationToken)
    {
        var question = new TelegramQuestion(
            RequiredString(request, "id", 128),
            RequiredString(request, "projectSlug", 128),
            RequiredString(request, "title", 512),
            OptionalString(request, "answer", 4096),
            OptionalString(request, "answeredBy", 128));
        await _handler.RecordQuestionAsync(question, cancellationToken).ConfigureAwait(false);
        return new { questionId = question.Id, recorded = true };
    }

    public async Task<object?> ExecuteCommandAsync(
        JsonElement request,
        CancellationToken cancellationToken)
    {
        string text = RequiredString(request, "text", TelegramBotClient.MaximumMessageCharacters);
        TelegramCommandRequest command = TelegramCommandParser.Parse(
            text,
            OptionalString(request, "actor", 128) ?? "companion")
            ?? throw new ArgumentException("The notification command is unknown.", nameof(request));
        TelegramCommandResponse response = await _handler
            .HandleAsync(command, cancellationToken)
            .ConfigureAwait(false);
        return new { ok = response.Ok, message = response.Message };
    }

    private static string RequiredString(JsonElement request, string property, int maximumCharacters)
    {
        string? value = OptionalString(request, property, maximumCharacters);
        return value ?? throw new ArgumentException($"{property} is required.", nameof(request));
    }

    private static string? OptionalString(JsonElement request, string property, int maximumCharacters)
    {
        if (!request.TryGetProperty(property, out JsonElement element)
            || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind != JsonValueKind.String)
        {
            throw new ArgumentException($"{property} must be a string.", nameof(request));
        }

        string value = (element.GetString() ?? string.Empty).Trim();
        if (value.Length is 0 || value.Length > maximumCharacters)
        {
            throw new ArgumentException(
                $"{property} must contain 1 to {maximumCharacters} characters.",
                nameof(request));
        }

        return value;
    }

    private static bool? OptionalBoolean(JsonElement request, string property)
    {
        if (!request.TryGetProperty(property, out JsonElement element))
        {
            return null;
        }
        return element.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new ArgumentException($"{property} must be a boolean.", nameof(request)),
        };
    }

    private static DateTimeOffset? OptionalTimestamp(JsonElement request, string property)
    {
        string? value = OptionalString(request, property, 64);
        if (value is null)
        {
            return null;
        }
        if (!DateTimeOffset.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out DateTimeOffset parsed))
        {
            throw new ArgumentException($"{property} must be an ISO-8601 timestamp.", nameof(request));
        }
        return parsed;
    }
}
