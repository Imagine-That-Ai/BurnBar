// Parity source: AgentLens/Services/Cast/CastMessageFraming.swift (struct CastMessage)

namespace OpenBurnBar.Integrations.Cast.Protocol;

/// <summary>
/// A single Cast V2 control-channel message, mirroring the subset of the
/// <c>cast_channel.proto</c> <c>CastMessage</c> we use.
/// </summary>
/// <remarks>
/// proto2 fields (see the header of the parity Swift file):
/// <list type="bullet">
///   <item>1: protocol_version (enum, varint) — always CASTV2_1_0 = 0</item>
///   <item>2: source_id (string)</item>
///   <item>3: destination_id (string)</item>
///   <item>4: namespace (string)</item>
///   <item>5: payload_type (enum, varint) — STRING = 0, BINARY = 1</item>
///   <item>6: payload_utf8 (string)</item>
///   <item>7: payload_binary (bytes) — unused</item>
/// </list>
/// This is a value type with structural equality (a C# <c>record</c>), matching
/// the Swift <c>Equatable</c> struct.
/// </remarks>
public sealed record CastMessage
{
    /// <summary>Cast payload discriminator. STRING carries JSON; BINARY is unused.</summary>
    public enum PayloadType
    {
        /// <summary>UTF-8 JSON payload in <see cref="PayloadUtf8"/> (proto value 0).</summary>
        String = 0,

        /// <summary>Binary payload (proto value 1) — not produced by this port.</summary>
        Binary = 1,
    }

    /// <summary>The conventional sender virtual channel id.</summary>
    public const string DefaultSource = "sender-0";

    /// <summary>The conventional receiver (platform) virtual channel id.</summary>
    public const string DefaultDestination = "receiver-0";

    /// <summary>Sending virtual-channel id (e.g. <c>sender-0</c> or a transport id).</summary>
    public required string SourceId { get; init; }

    /// <summary>Receiving virtual-channel id (e.g. <c>receiver-0</c> or a transport id).</summary>
    public required string DestinationId { get; init; }

    /// <summary>Cast namespace URN, e.g. <c>urn:x-cast:com.google.cast.receiver</c>.</summary>
    public required string Namespace { get; init; }

    /// <summary>UTF-8 JSON payload (when <see cref="Type"/> is <see cref="PayloadType.String"/>).</summary>
    public required string PayloadUtf8 { get; init; }

    /// <summary>Payload discriminator; defaults to <see cref="PayloadType.String"/>.</summary>
    public PayloadType Type { get; init; } = PayloadType.String;

    /// <summary>
    /// Construct a string-payload message from the default sender to the given
    /// destination — the common outbound case.
    /// </summary>
    public static CastMessage String(string @namespace, string payloadUtf8, string destination)
        => new()
        {
            SourceId = DefaultSource,
            DestinationId = destination,
            Namespace = @namespace,
            PayloadUtf8 = payloadUtf8,
            Type = PayloadType.String,
        };
}
