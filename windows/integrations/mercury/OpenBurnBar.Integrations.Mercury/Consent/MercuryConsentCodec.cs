using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.Integrations.Mercury.Consent;

/// <summary>
/// JSON codec for the consent grant ledger (parity: the JSONEncoder /
/// JSONDecoder path in MercuryConsentStore). Provides the fail-closed
/// <see cref="TryEncode"/> that returns <c>null</c> (and logs) on an encode
/// fault so the caller leaves the persisted ledger intact.
/// </summary>
public static class MercuryConsentCodec
{
    private static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public static byte[] Encode(IReadOnlyList<MirrorAutoAcceptGrant> grants)
    {
        var dtos = new List<GrantDto>(grants.Count);
        foreach (var g in grants)
        {
            dtos.Add(GrantDto.From(g));
        }

        return JsonSerializer.SerializeToUtf8Bytes(dtos, Options);
    }

    public static IReadOnlyList<MirrorAutoAcceptGrant> Decode(byte[] data)
    {
        var dtos = JsonSerializer.Deserialize<List<GrantDto>>(data, Options) ?? new List<GrantDto>();
        var grants = new List<MirrorAutoAcceptGrant>(dtos.Count);
        foreach (var dto in dtos)
        {
            grants.Add(dto.ToGrant());
        }

        return grants;
    }

    /// <summary>
    /// Encode with fail-closed semantics: returns <c>null</c> on an encoder
    /// throw (invoking <paramref name="faultLogger"/> with a class name + grant
    /// count) so the caller keeps the prior persisted ledger (parity:
    /// encodeGrants returning nil).
    /// </summary>
    public static byte[]? TryEncode(
        IReadOnlyList<MirrorAutoAcceptGrant> grants,
        Func<IReadOnlyList<MirrorAutoAcceptGrant>, byte[]> encode,
        Action<string, int>? faultLogger)
    {
        try
        {
            return encode(grants);
        }
        catch (Exception ex)
        {
            faultLogger?.Invoke(ex.GetType().Name, grants.Count);
            return null;
        }
    }

    private sealed class GrantDto
    {
        [JsonPropertyName("key")]
        public string Key { get; set; } = string.Empty;

        [JsonPropertyName("connectionId")]
        public string ConnectionId { get; set; } = string.Empty;

        [JsonPropertyName("viewerDeviceId")]
        public string? ViewerDeviceId { get; set; }

        [JsonPropertyName("controlAuthorityPeerNodeId")]
        public string? ControlAuthorityPeerNodeId { get; set; }

        [JsonPropertyName("requesterName")]
        public string RequesterName { get; set; } = string.Empty;

        [JsonPropertyName("grantedAt")]
        public DateTimeOffset GrantedAt { get; set; }

        [JsonPropertyName("expiresAt")]
        public DateTimeOffset ExpiresAt { get; set; }

        [JsonPropertyName("lastUsedAt")]
        public DateTimeOffset? LastUsedAt { get; set; }

        public static GrantDto From(MirrorAutoAcceptGrant g) => new()
        {
            Key = g.Key,
            ConnectionId = g.ConnectionId,
            ViewerDeviceId = g.ViewerDeviceId,
            ControlAuthorityPeerNodeId = g.ControlAuthorityPeerNodeId,
            RequesterName = g.RequesterName,
            GrantedAt = g.GrantedAt,
            ExpiresAt = g.ExpiresAt,
            LastUsedAt = g.LastUsedAt,
        };

        public MirrorAutoAcceptGrant ToGrant() => new(
            Key,
            ConnectionId,
            ViewerDeviceId,
            ControlAuthorityPeerNodeId,
            RequesterName,
            GrantedAt,
            ExpiresAt,
            LastUsedAt);
    }
}
