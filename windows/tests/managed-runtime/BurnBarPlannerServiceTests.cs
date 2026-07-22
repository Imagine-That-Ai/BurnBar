using System;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class BurnBarPlannerServiceTests
{
    private readonly BurnBarPlannerService _planner = new();

    [Fact]
    public void PlanRaw_NormalizesReplaceWorkflowAndExactOutline()
    {
        using JsonDocument metadata = JsonDocument.Parse("""
            {"workspaceWorkflow":{"type":"replace_string_in_file","path":"Sources/App.swift","from":"old","to":"new"}}
            """);

        BurnBarPlannedRun planned = _planner.PlanRaw("Change a string", metadata.RootElement);

        Assert.Equal(BurnBarAgentIntentKind.ReplaceStringInFile, planned.Intent.Kind);
        Assert.Equal("Sources/App.swift", planned.Intent.TargetPath);
        Assert.Equal("old", planned.Intent.Replacement?.From);
        Assert.Equal(new[] { BurnBarToolKind.ReadFile, BurnBarToolKind.ApplyPatch }, planned.Intent.RequestedTools);
        Assert.Equal("Verify result", planned.Outline.Steps[^1].Title);
    }

    [Fact]
    public void PlanRaw_NormalizesTerminalToolMetadata()
    {
        using JsonDocument metadata = JsonDocument.Parse("""
            {"toolKind":"run_terminal","toolArguments":{"command":"npm test","cwd":"app","preserveFocus":true}}
            """);

        BurnBarPlannedRun planned = _planner.PlanRaw("Run tests", metadata.RootElement);

        Assert.Equal(BurnBarAgentIntentKind.RunTerminal, planned.Intent.Kind);
        Assert.Equal("npm test", planned.Intent.TerminalCommand?.Command);
        Assert.Equal("app", planned.Intent.TerminalCommand?.Cwd);
        Assert.True(planned.Intent.TerminalCommand?.PreserveFocus);
        Assert.Equal(BurnBarToolKind.RunTerminal, Assert.Single(planned.Intent.RequestedTools!));
    }

    [Theory]
    [InlineData("search for BurnBarRunService", BurnBarAgentIntentKind.InspectWorkspace, "BurnBarRunService")]
    [InlineData("find PlannerService", BurnBarAgentIntentKind.InspectWorkspace, "PlannerService")]
    [InlineData("do something vague", BurnBarAgentIntentKind.Generic, null)]
    public void PlanRaw_NormalizesPromptOrFallsBack(
        string prompt,
        BurnBarAgentIntentKind expectedKind,
        string? expectedQuery)
    {
        BurnBarPlannedRun planned = _planner.PlanRaw(prompt);

        Assert.Equal(expectedKind, planned.Intent.Kind);
        Assert.Equal(expectedQuery, planned.Intent.SearchQuery);
        Assert.Equal(3, planned.Outline.Steps.Count);
    }

    [Fact]
    public void PlanRaw_InfersReplacementAndTerminalWorkingDirectory()
    {
        using JsonDocument replacementMetadata = JsonDocument.Parse("""
            {"activeFilePath":"src/example.ts","activeSelectionText":"selected text"}
            """);
        BurnBarPlannedRun replacement = _planner.PlanRaw(
            "change this selection to \"updated text\"",
            replacementMetadata.RootElement);
        BurnBarPlannedRun terminal = _planner.PlanRaw(
            "run npm test",
            JsonSerializer.SerializeToElement(new { activeFilePath = "app/src/example.ts" }));

        Assert.Equal("selected text", replacement.Intent.Replacement?.From);
        Assert.Equal("updated text", replacement.Intent.Replacement?.To);
        Assert.Equal("app/src", terminal.Intent.TerminalCommand?.Cwd);
    }

    [Fact]
    public void PlanRaw_UsesExplicitWorkflowToolPromptGenericPrecedence()
    {
        using JsonDocument allSources = JsonDocument.Parse("""
            {
              "agentIntent":{"kind":"inspect_workspace","objective":"explicit","summary":"explicit wins","searchQuery":"needle"},
              "workspaceWorkflow":{"type":"replace_string_in_file","path":"ignored","from":"a","to":"b"},
              "toolKind":"run_terminal","toolArguments":{"command":"ignored"}
            }
            """);
        using JsonDocument workflowAndTool = JsonDocument.Parse("""
            {
              "workspaceWorkflow":{"type":"replace_string_in_file","path":"File.swift","from":"a","to":"b"},
              "toolKind":"run_terminal","toolArguments":{"command":"ignored"}
            }
            """);
        using JsonDocument toolAndPrompt = JsonDocument.Parse("""
            {"toolKind":"search_workspace","toolArguments":{"query":"specific query"}}
            """);

        Assert.Equal("explicit wins", _planner.PlanRaw("run ignored", allSources.RootElement).Intent.Summary);
        Assert.Equal(BurnBarAgentIntentKind.ReplaceStringInFile, _planner.PlanRaw("run ignored", workflowAndTool.RootElement).Intent.Kind);
        Assert.Equal("specific query", _planner.PlanRaw("replace \"a\" with \"b\"", toolAndPrompt.RootElement).Intent.SearchQuery);
    }

    [Fact]
    public void PlanRaw_InfersToolsOnlyWhenExplicitIntentOmitsThem()
    {
        BurnBarPlannedRun inferred = _planner.PlanRaw(
            "inspect",
            JsonSerializer.SerializeToElement(new
            {
                agentIntent = new
                {
                    kind = "inspect_workspace",
                    objective = "inspect",
                    summary = "inspect summary",
                    searchQuery = "needle",
                },
            }));
        BurnBarPlannedRun explicitEmpty = _planner.PlanRaw(
            "inspect",
            JsonSerializer.SerializeToElement(new
            {
                agentIntent = new
                {
                    kind = "inspect_workspace",
                    objective = "inspect",
                    summary = "inspect summary",
                    searchQuery = "needle",
                    requestedTools = Array.Empty<string>(),
                },
            }));

        Assert.Equal(BurnBarToolKind.SearchWorkspace, Assert.Single(inferred.Intent.RequestedTools!));
        Assert.Empty(explicitEmpty.Intent.RequestedTools!);
    }

    [Fact]
    public void PlanRaw_InfersToolsWhenExplicitIntentUsesJsonNull()
    {
        using JsonDocument metadata = JsonDocument.Parse("""
            {"agentIntent":{"kind":"inspect_workspace","objective":"inspect","summary":"summary","requestedTools":null}}
            """);

        BurnBarPlannedRun planned = _planner.PlanRaw("inspect", metadata.RootElement);

        Assert.Equal(BurnBarToolKind.SearchWorkspace, Assert.Single(planned.Intent.RequestedTools!));
    }

    [Fact]
    public void PlanRaw_UnsupportedWorkflowFailsBeforeValidToolFallback()
    {
        using JsonDocument metadata = JsonDocument.Parse("""
            {
              "workspaceWorkflow":{"type":"unsupported","path":"File.swift","from":"a","to":"b"},
              "toolKind":"run_terminal","toolArguments":{"command":"npm test"}
            }
            """);

        BurnBarPlannerException error = Assert.Throws<BurnBarPlannerException>(() =>
            _planner.PlanRaw("Run tests", metadata.RootElement));

        Assert.Equal("unsupported_workflow", error.Code);
    }

    [Fact]
    public void PlanTyped_ValidatesRequiredFieldsAndSchema()
    {
        var intent = new BurnBarAgentIntent(
            BurnBarAgentIntentKind.Generic,
            "test",
            "test summary");

        BurnBarPlannerException constraints = Assert.Throws<BurnBarPlannerException>(() =>
            _planner.PlanTyped(new BurnBarPlannerInput(
                1,
                "mission-1",
                intent,
                Array.Empty<string>(),
                BurnBarToolRisk.Low,
                new[] { "output" })));
        BurnBarPlannerException outputs = Assert.Throws<BurnBarPlannerException>(() =>
            _planner.PlanTyped(new BurnBarPlannerInput(
                1,
                "mission-1",
                intent,
                new[] { "constraint" },
                BurnBarToolRisk.Low,
                Array.Empty<string>())));
        BurnBarPlannerException schema = Assert.Throws<BurnBarPlannerException>(() =>
            _planner.PlanTyped(new BurnBarPlannerInput(
                99,
                "mission-1",
                intent,
                new[] { "constraint" },
                BurnBarToolRisk.Low,
                new[] { "output" })));

        Assert.Contains("constraints", constraints.Message, StringComparison.Ordinal);
        Assert.Contains("desiredOutputs", outputs.Message, StringComparison.Ordinal);
        Assert.Equal("unsupported_schema_version", schema.Code);
    }

    [Fact]
    public void ParseAndPlanTyped_PreservesConstraintsRiskAndDesiredOutputs()
    {
        using JsonDocument input = JsonDocument.Parse("""
            {
              "schemaVersion":1,
              "missionID":"mission-2",
              "normalizedIntent":{
                "kind":"inspect_workspace",
                "objective":"find relevant files",
                "summary":"workspace inspection",
                "searchQuery":"BurnBarRunService",
                "requestedTools":["search_workspace"]
              },
              "constraints":["only search src/"],
              "riskLevel":"low",
              "desiredOutputs":["files identified"],
              "workflowHints":{"scope":"src"}
            }
            """);

        BurnBarPlannedRun planned = _planner.PlanTyped(_planner.ParseTypedInput(input.RootElement));

        Assert.Equal("find relevant files", planned.Outline.Objective);
        Assert.Equal("only search src/", Assert.Single(planned.Constraints));
        Assert.Equal(BurnBarToolRisk.Low, planned.RiskLevel);
        Assert.Equal("files identified", Assert.Single(planned.DesiredOutputs));
        Assert.Equal("Summarize findings", planned.Outline.Steps.Last().Title);
    }
}
