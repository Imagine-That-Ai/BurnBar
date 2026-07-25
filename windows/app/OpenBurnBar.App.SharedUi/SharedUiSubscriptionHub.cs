using System;
using System.Collections.Generic;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// subscription_start / subscription_resume / subscription_stop — a host-local
/// event-subscription authority that satisfies the frontend's STRICT decoders
/// (decodeDaemonSubscriptionResponse / decodeDaemonSubscriptionStopResponse in
/// tauriBridge.ts) and the health supervisor's invariants:
///
///   * snake_case end-to-end (subscription_id, first_snapshot, degraded_fallback,
///     backpressure, disconnect_detected, recovered_after_restart,
///     terminal_state_delivered, last_seq);
///   * subscription_id constant across resumes (echoes requested_subscription_id);
///   * seq a non-negative safe integer, strictly increasing per subscription;
///   * cursor a non-empty string; events[] (zero here) snapshots string-valued;
///   * terminal_state_delivered false, no terminal events — the supervisor
///     polls forever without ever concluding the stream ended.
///
/// Windows serves data from in-process stores that the surfaces poll directly,
/// so the event plane is honestly empty: degraded_fallback true with a
/// degradation_reason saying exactly that.
/// </summary>
public sealed class SharedUiSubscriptionHub
{
    private const string Backpressure = "coalesce_latest_per_topic";
    private const string DegradationReason =
        "Windows shell serves data from in-process stores; the daemon event bus does not exist (WPD-0006).";

    private readonly object _gate = new();
    private readonly Dictionary<string, long> _seqBySubscription = new(StringComparer.Ordinal);
    private long _nextSubscriptionNumber = 1;

    /// <summary>subscription_start — { request: { topic, run_id?, requested_subscription_id?, client_id? } }.</summary>
    public JsonObject Start(JsonObject args)
    {
        var request = args["request"] as JsonObject ?? new JsonObject();
        var topic = ReadTopic(request);
        var requestedId = ReadString(request, "requested_subscription_id");

        lock (_gate)
        {
            var subscriptionId = !string.IsNullOrEmpty(requestedId)
                ? requestedId
                : $"windows-shared-{_nextSubscriptionNumber++}";
            var seq = NextSeqLocked(subscriptionId, afterSeq: -1);
            return BuildResponse(subscriptionId, topic, seq, firstSnapshot: true);
        }
    }

    /// <summary>subscription_resume — { request: { subscription_id, topic, after_seq, run_id?, client_id? } }.</summary>
    public JsonObject Resume(JsonObject args)
    {
        var request = args["request"] as JsonObject ?? new JsonObject();
        var topic = ReadTopic(request);
        var subscriptionId = ReadString(request, "subscription_id");
        if (string.IsNullOrEmpty(subscriptionId))
        {
            throw new SharedUiCommandException("subscription.subscription_id must be a non-empty string.");
        }

        var afterSeq = request["after_seq"] is JsonValue seqValue && seqValue.TryGetValue(out long s) && s >= 0
            ? s
            : 0L;

        lock (_gate)
        {
            var seq = NextSeqLocked(subscriptionId, afterSeq);
            return BuildResponse(subscriptionId, topic, seq, firstSnapshot: false);
        }
    }

    /// <summary>subscription_stop — { request: { subscription_id, client_id? } }.</summary>
    public JsonObject Stop(JsonObject args)
    {
        var request = args["request"] as JsonObject ?? new JsonObject();
        var subscriptionId = ReadString(request, "subscription_id") ?? string.Empty;

        lock (_gate)
        {
            var lastSeq = _seqBySubscription.TryGetValue(subscriptionId, out var seq) ? seq : 0L;
            _seqBySubscription.Remove(subscriptionId);
            return new JsonObject
            {
                ["subscription_id"] = subscriptionId,
                ["stopped"] = true,
                ["last_seq"] = lastSeq,
            };
        }
    }

    private long NextSeqLocked(string subscriptionId, long afterSeq)
    {
        var previous = _seqBySubscription.TryGetValue(subscriptionId, out var seq) ? seq : 0L;
        var next = Math.Max(previous + 1, afterSeq + 1);
        _seqBySubscription[subscriptionId] = next;
        return next;
    }

    private static JsonObject BuildResponse(string subscriptionId, string topic, long seq, bool firstSnapshot) =>
        new()
        {
            ["subscription_id"] = subscriptionId,
            ["topic"] = topic,
            ["seq"] = seq,
            ["cursor"] = seq.ToString(),
            ["first_snapshot"] = firstSnapshot,
            ["events"] = new JsonArray(),
            ["degraded_fallback"] = true,
            ["degradation_reason"] = DegradationReason,
            ["backpressure"] = Backpressure,
            ["disconnect_detected"] = false,
            ["recovered_after_restart"] = false,
            ["terminal_state_delivered"] = false,
        };

    private static string ReadTopic(JsonObject request)
    {
        var topic = ReadString(request, "topic");
        return topic is "data" or "health" or "run"
            ? topic
            : throw new SharedUiCommandException("subscription.topic is unsupported.");
    }

    private static string? ReadString(JsonObject obj, string key) =>
        obj[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;
}
