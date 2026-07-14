using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Projects;
using OpenBurnBar.App.Run;
using OpenBurnBar.App.Settings.Winui;

namespace OpenBurnBar.App;

public partial class App
{
    private CompanionCliServer? _companionCli;
    private HeadlessRunService? _headlessRuns;
    private HeadlessAgentRunService? _headlessAgentRuns;

    private void StartCompanionCli()
    {
        HeadlessAgentRunService? agentRuns = null;
        try
        {
            int port = 8765;
            string? configuredPort = Environment.GetEnvironmentVariable("OPENBURNBAR_COMPANION_CLI_PORT");
            if (int.TryParse(configuredPort, out int parsedPort) && parsedPort is > 0 and <= 65535)
            {
                port = parsedPort;
            }

            string localData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenBurnBar");
            string journalPath = Environment.GetEnvironmentVariable("OPENBURNBAR_RUN_JOURNAL_PATH")
                ?? Path.Combine(localData, "headless-runs.jsonl");
            var headlessRuns = new HeadlessRunService(new JsonLinesHeadlessRunJournal(journalPath));
            _headlessRuns = headlessRuns;
            if (_localAccessToken is null)
            {
                GatewayEndpointSettings settings = WindowsSettingsComposition.LoadGatewayEndpointSettings();
                _localAccessToken = ResolveGatewayAccessToken(
                    new GatewayListenerOptions(true, "127.0.0.1", port),
                    settings);
            }

            CompanionCliAgentRunHandler? agentHandler = null;
            if (_gatewayComposition is not null)
            {
                string agentJournalPath = Environment.GetEnvironmentVariable("OPENBURNBAR_AGENT_RUN_JOURNAL_PATH")
                    ?? Path.Combine(localData, "headless-agent-runs.jsonl");
                agentRuns = new HeadlessAgentRunService(
                    _gatewayComposition.Router,
                    _gatewayComposition.Executor,
                    new JsonLinesHeadlessRunJournal(agentJournalPath),
                    ProtectedHeadlessAgentCheckpointStore.CreateDefault());
                agentRuns.StartAsync().GetAwaiter().GetResult();
                _headlessAgentRuns = agentRuns;
                agentHandler = new CompanionCliAgentRunHandler(agentRuns);
            }

            var runHandler = new CompanionCliHeadlessRunHandler(
                headlessRuns,
                BuiltInHeadlessRunSteps.ExecuteAsync,
                agentHandler);
            var missionHandler = new CompanionCliMissionHandler(
                new LocalMissionDagExecutor(
                    headlessRuns,
                    rateLimiter: new MissionRateLimiter(60, TimeSpan.FromMinutes(1))));
            var plannerHandler = new CompanionCliPlannerHandler(new BurnBarPlannerService());
            var policyHandler = new CompanionCliPolicyHandler(new BurnBarPlannerService(), new BurnBarPolicyEngine());
            _ = ReportRecoverableHeadlessRunsAsync(headlessRuns);
            string fusionJournalPath = Environment.GetEnvironmentVariable("OPENBURNBAR_FUSION_JOURNAL_PATH")
                ?? Path.Combine(localData, "elder-wand-runs.jsonl");
            _fusion = new ElderWandFusionOrchestrator(
                ExecuteFusionToolAsync,
                new JsonLinesFusionRunJournal(fusionJournalPath));
            EnsureProjectCodeMemoryStarted();
            var router = new CompanionCliCommandRouter(
                _gatewayComposition?.Router,
                runHandler.SubmitAsync,
                runHandler.ResumeAsync,
                HandleFusionRunAsync,
                HandleProjectCodeAsync,
                runHandler.RecoverAsync,
                missionHandler.SubmitAsync,
                missionHandler.ResumeAsync,
                plannerHandler.PlanAsync,
                policyHandler.EvaluateAsync,
                agentHandler);
            _companionCli = new CompanionCliServer(port, router, _localAccessToken);
            _companionCli.Start();
            AppDiagnostics.LogEvent("companion-cli.started", $"127.0.0.1:{port}");
        }
        catch (Exception ex)
        {
            if (agentRuns is not null)
            {
                try { agentRuns.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
                catch (Exception disposeError) { AppDiagnostics.LogException("headless-agent.dispose-after-start-failure", disposeError); }
            }
            AppDiagnostics.LogException("companion-cli.start", ex);
            _companionCli = null;
            _headlessRuns = null;
            _headlessAgentRuns = null;
            _fusion = null;
        }
    }

    private void EnsureProjectCodeMemoryStarted()
    {
        if (Volatile.Read(ref _projectCodeMemory) is not null) return;
        ProjectCodeMemoryService? projectCodeMemory = CreateProjectCodeMemoryService();
        if (projectCodeMemory is null) return;
        projectCodeMemory.TryLoad();
        projectCodeMemory.StartWatching();
        ProjectCodeMemoryService? concurrent = Interlocked.CompareExchange(
            ref _projectCodeMemory,
            projectCodeMemory,
            null);
        if (concurrent is null)
        {
            _ = RefreshProjectCodeMemoryAsync(projectCodeMemory);
        }
        else
        {
            projectCodeMemory.Dispose();
        }
    }

    private static async Task ReportRecoverableHeadlessRunsAsync(HeadlessRunService service)
    {
        try
        {
            IReadOnlyList<RecoverableHeadlessRun> runs = await service
                .RecoverAsync()
                .ConfigureAwait(false);
            if (runs.Count > 0)
            {
                AppDiagnostics.LogEvent("headless-runs.recoverable", runs.Count.ToString());
            }
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("headless-runs.recovery", ex);
        }
    }
}
