using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.Settings.Winui;

namespace OpenBurnBar.App;

public partial class App
{
    private TelegramBotClient? _telegramClient;
    private TelegramPollingService? _telegramPolling;

    private TelegramMissionCommandHandler CreateTelegramCommandHandler() =>
        new(
            new ProtectedTelegramMissionStateStore(WindowsSettingsComposition.SharedPersistence),
            TelegramStatusAsync,
            LaunchTelegramReviewAsync);

    private void StartTelegramRuntime(
        string localData,
        TelegramMissionCommandHandler commandHandler)
    {
        try
        {
            var client = new TelegramBotClient();
            var polling = new TelegramPollingService(
                client,
                LoadTelegramConfiguration,
                new JsonFileTelegramUpdateOffsetStore(
                    Path.Combine(localData, "telegram-update-offset.json")),
                commandHandler.HandleAsync,
                commandHandler.TakeDueFollowupMessagesAsync,
                error => AppDiagnostics.LogException("telegram.poll", error));
            polling.Start();
            _telegramClient = client;
            _telegramPolling = polling;
            AppDiagnostics.LogEvent("telegram.started", "dynamic-settings");
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("telegram.start", error);
            _telegramPolling = null;
            _telegramClient?.Dispose();
            _telegramClient = null;
        }
    }

    private static TelegramBridgeConfiguration LoadTelegramConfiguration()
    {
        NotificationSettingsSnapshot settings = WindowsSettingsComposition.LoadNotificationSettings();
        return new TelegramBridgeConfiguration(
            settings.TelegramEnabled,
            settings.TelegramBotToken,
            settings.TelegramChatId,
            TimeSpan.FromSeconds(5),
            settings.DefaultSnoozeMinutes);
    }

    private async Task<string> TelegramStatusAsync(CancellationToken cancellationToken)
    {
        int routeCount = _gatewayComposition?.Router.Routes.Count ?? 0;
        if (_headlessAgentRuns is null)
        {
            return $"Gateway routes: {routeCount}, active Telegram runs: 0.";
        }

        var runs = await _headlessAgentRuns
            .PollAsync("telegram", limit: 20, cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        int active = runs.Count(run => run.Phase is not (
            HeadlessAgentRunPhase.Completed
            or HeadlessAgentRunPhase.Failed
            or HeadlessAgentRunPhase.Cancelled));
        return $"Gateway routes: {routeCount}, active Telegram runs: {active}, recent Telegram runs: {runs.Count}.";
    }

    private async Task<string> LaunchTelegramReviewAsync(
        string project,
        bool weekly,
        CancellationToken cancellationToken)
    {
        if (_headlessAgentRuns is null || _gatewayComposition is null)
        {
            throw new TelegramBotException("The local review runtime is unavailable.");
        }

        ModelRoute? route = _gatewayComposition.Router.Routes
            .Where(item => item.IsExecutable && item.IsAvailable())
            .OrderBy(item => item.Priority)
            .FirstOrDefault(item => _gatewayComposition.Router.ActiveHealthFailure(item) is null);
        if (route is null)
        {
            throw new TelegramBotException("No healthy model route is available for the review.");
        }

        string cadence = weekly ? "weekly" : "daily";
        string runId = $"telegram-{cadence}-{Guid.NewGuid():N}";
        JsonElement metadata = JsonSerializer.SerializeToElement(new
        {
            origin = "telegram",
            cadence,
            project,
        });
        HeadlessAgentRunSnapshot run = await _headlessAgentRuns.SubmitAsync(
            new HeadlessAgentRunRequest(
                runId,
                "telegram",
                $"telegram-{project}",
                $"Run the {cadence} OpenBurnBar project review for '{project}'. "
                    + "Summarize current progress, unresolved risks, and the highest-value next actions.",
                route.Model,
                RequiresApproval: false,
                metadata),
            cancellationToken).ConfigureAwait(false);
        return run.RunId;
    }

    private sealed class ProtectedTelegramMissionStateStore : ITelegramMissionStateStore
    {
        private const int MaximumSerializedCharacters = 512 * 1024;
        private static readonly string SecretName = AppSecretNames.ProviderSecret(
            "mission-control",
            "telegram",
            "state");
        private readonly WindowsSettingsPersistence _persistence;

        public ProtectedTelegramMissionStateStore(WindowsSettingsPersistence persistence)
        {
            _persistence = persistence ?? throw new ArgumentNullException(nameof(persistence));
        }

        public ValueTask<TelegramMissionState> LoadAsync(
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            string json = _persistence.ReadSecret(SecretName);
            if (string.IsNullOrWhiteSpace(json) || json.Length > MaximumSerializedCharacters)
            {
                return ValueTask.FromResult(TelegramMissionState.Empty);
            }

            try
            {
                return ValueTask.FromResult(
                    JsonSerializer.Deserialize<TelegramMissionState>(json)
                    ?? TelegramMissionState.Empty);
            }
            catch (JsonException)
            {
                return ValueTask.FromResult(TelegramMissionState.Empty);
            }
        }

        public ValueTask SaveAsync(
            TelegramMissionState state,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            string json = JsonSerializer.Serialize(state);
            if (json.Length > MaximumSerializedCharacters)
            {
                throw new InvalidOperationException("Telegram Mission Control state exceeds the protected-storage limit.");
            }

            _persistence.WriteSecret(SecretName, json);
            return ValueTask.CompletedTask;
        }
    }
}
