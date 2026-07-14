using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

public sealed class ConnectorPlaneServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task Snapshot_ContainsAllConnectorsDisabledByDefault()
    {
        var fixture = Fixture();
        ConnectorPlaneSnapshot snapshot = await fixture.Service.SnapshotAsync();
        Assert.Equal(6, snapshot.Connectors.Count);
        Assert.All(snapshot.Connectors, connector => Assert.Equal(ConnectorHealthStatus.Disabled, connector.Status));
    }

    [Fact]
    public async Task Update_PersistsConfigButNeverSecret()
    {
        var fixture = Fixture();
        ConnectorPlaneSnapshot snapshot = await fixture.Service.UpdateConfigAsync(new ConnectorConfigUpdateRequest(
            new ConnectorConfigMutation(ConnectorKind.Github, true, "https://api.github.com", ConnectorAuthKind.BearerToken),
            "ghp_super-secret", true));
        ConnectorConfigSnapshot github = Assert.Single(snapshot.Connectors, item => item.Kind == ConnectorKind.Github);
        Assert.True(github.SecretConfigured);
        Assert.Equal("gh...et", github.SecretHint);
        Assert.DoesNotContain("super-secret", fixture.State.Json, StringComparison.Ordinal);
        Assert.Equal("ghp_super-secret", fixture.Secrets.Read(ConnectorKind.Github));
    }

    [Theory]
    [InlineData("http://api.github.com")]
    [InlineData("https://127.0.0.1")]
    [InlineData("https://169.254.169.254")]
    [InlineData("https://user:pass@example.com")]
    public async Task Update_RejectsUnsafeDestinations(string url)
    {
        var fixture = Fixture();
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Service.UpdateConfigAsync(new ConnectorConfigUpdateRequest(
            new ConnectorConfigMutation(ConnectorKind.Github, true, url, ConnectorAuthKind.BearerToken))));
    }

    [Fact]
    public async Task Update_RejectsMixedPublicPrivateDnsAnswer()
    {
        var fixture = Fixture((_, _) => Task.FromResult(new[] { IPAddress.Parse("93.184.216.34"), IPAddress.Loopback }));
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Service.UpdateConfigAsync(new ConnectorConfigUpdateRequest(
            new ConnectorConfigMutation(ConnectorKind.Github, true, "https://example.com", ConnectorAuthKind.BearerToken))));
    }

    [Fact]
    public async Task Action_FailsClosedWhenDisabledOrMissingSecret()
    {
        var fixture = Fixture();
        ConnectorActionResponse disabled = await fixture.Service.PerformActionAsync(
            new ConnectorActionRequest(ConnectorKind.Github, ConnectorActionKind.TestConnection));
        Assert.False(disabled.Ok);
        Assert.Contains("disabled", disabled.Summary, StringComparison.OrdinalIgnoreCase);

        await fixture.Service.UpdateConfigAsync(new ConnectorConfigUpdateRequest(
            new ConnectorConfigMutation(ConnectorKind.Github, true, "https://api.github.com", ConnectorAuthKind.BearerToken)));
        ConnectorActionResponse missing = await fixture.Service.PerformActionAsync(
            new ConnectorActionRequest(ConnectorKind.Github, ConnectorActionKind.TestConnection));
        Assert.False(missing.Ok);
        Assert.Contains("credentials", missing.Summary, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, fixture.Transport.Calls);
    }

    [Fact]
    public async Task Action_SendsCredentialOnlyInHeaderAndRecordsHealthyResult()
    {
        var fixture = Fixture();
        await fixture.Service.UpdateConfigAsync(new ConnectorConfigUpdateRequest(
            new ConnectorConfigMutation(ConnectorKind.Github, true, "https://api.github.com", ConnectorAuthKind.BearerToken),
            "ghp_secret", true));
        fixture.Transport.Response = new ConnectorTransportResponse(200, "{\"login\":\"alberto\",\"html_url\":\"https://github.com/alberto\"}");
        ConnectorActionResponse response = await fixture.Service.PerformActionAsync(
            new ConnectorActionRequest(ConnectorKind.Github, ConnectorActionKind.TestConnection));
        Assert.True(response.Ok);
        Assert.Equal("Bearer ghp_secret", fixture.Transport.Authorization);
        Assert.DoesNotContain("ghp_secret", fixture.Transport.Url!, StringComparison.Ordinal);
        ConnectorPlaneSnapshot snapshot = await fixture.Service.SnapshotAsync();
        Assert.Equal(ConnectorHealthStatus.Healthy, snapshot.Connectors.Single(item => item.Kind == ConnectorKind.Github).Status);
        Assert.DoesNotContain("ghp_secret", fixture.State.Json, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Action_RecordsDegradedWithoutLeakingCredential()
    {
        var fixture = Fixture();
        await fixture.Service.UpdateConfigAsync(new ConnectorConfigUpdateRequest(
            new ConnectorConfigMutation(ConnectorKind.Github, true, "https://api.github.com", ConnectorAuthKind.BearerToken), "token", true));
        fixture.Transport.Response = new ConnectorTransportResponse(401, "denied");
        ConnectorActionResponse response = await fixture.Service.PerformActionAsync(
            new ConnectorActionRequest(ConnectorKind.Github, ConnectorActionKind.SampleRequest));
        Assert.False(response.Ok);
        Assert.Equal(ConnectorHealthStatus.Degraded,
            (await fixture.Service.SnapshotAsync()).Connectors.Single(item => item.Kind == ConnectorKind.Github).Status);
        Assert.DoesNotContain("token", fixture.State.Json, StringComparison.Ordinal);
    }

    private static FixtureState Fixture(Func<string, CancellationToken, Task<IPAddress[]>>? resolver = null)
    {
        var state = new MemoryStateStore();
        var secrets = new MemoryConnectorSecrets();
        var transport = new RecordingTransport();
        var service = new ConnectorPlaneService(state, secrets, transport,
            resolver ?? ((_, _) => Task.FromResult(new[] { IPAddress.Parse("93.184.216.34") })), new FixedClock(Now));
        return new FixtureState(service, state, secrets, transport);
    }

    private sealed record FixtureState(ConnectorPlaneService Service, MemoryStateStore State,
        MemoryConnectorSecrets Secrets, RecordingTransport Transport);

    private sealed class MemoryStateStore : IConnectorPlaneStateStore
    {
        public string Json { get; private set; } = string.Empty;
        public string? Read() => string.IsNullOrEmpty(Json) ? null : Json;
        public void Write(string json) => Json = json;
    }

    private sealed class MemoryConnectorSecrets : IConnectorSecretStore
    {
        private readonly Dictionary<ConnectorKind, string> _values = new();
        public string? Read(ConnectorKind kind) => _values.GetValueOrDefault(kind);
        public void Write(ConnectorKind kind, string? secret)
        {
            if (string.IsNullOrWhiteSpace(secret)) _values.Remove(kind); else _values[kind] = secret.Trim();
        }
    }

    private sealed class RecordingTransport : IConnectorTransport
    {
        public ConnectorTransportResponse Response { get; set; } = new(200, "{}");
        public int Calls { get; private set; }
        public string? Authorization { get; private set; }
        public string? Url { get; private set; }
        public Task<ConnectorTransportResponse> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            Authorization = request.Headers.GetValues("Authorization").Single();
            Url = request.RequestUri?.AbsoluteUri;
            return Task.FromResult(Response);
        }
    }
}
