using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class HeadlessRunServiceTests
{
    [Fact]
    public async Task ExecuteAsync_RespectsDependenciesAndPersistsStateOnly()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-run-{Guid.NewGuid():N}.jsonl");
        try
        {
            var service = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var definition = new HeadlessRunDefinition("run-1", new[]
            {
                new HeadlessRunStep("compile", "compile", "secret-payload"),
                new HeadlessRunStep("test", "test", "test", new[] { "compile" }),
            });
            var order = new System.Collections.Generic.List<string>();

            HeadlessRunResult result = await service.ExecuteAsync(definition, (step, _) =>
            {
                order.Add(step.Id);
                return Task.FromResult(HeadlessRunStepResult.Ok());
            });

            Assert.Equal(HeadlessRunState.Succeeded, result.State);
            Assert.Equal(new[] { "compile", "test" }, order);
            string journal = await File.ReadAllTextAsync(path);
            Assert.DoesNotContain("secret-payload", journal, StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task RecoverAsync_FindsInterruptedRunAndResumeSkipsCompletedSteps()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-run-{Guid.NewGuid():N}.jsonl");
        try
        {
            var journal = new JsonLinesHeadlessRunJournal(path);
            var service = new HeadlessRunService(journal);
            var definition = new HeadlessRunDefinition("run-2", new[]
            {
                new HeadlessRunStep("a", "work", "a"),
                new HeadlessRunStep("b", "work", "b", new[] { "a" }),
            });

            await Assert.ThrowsAsync<InvalidOperationException>(() => service.ExecuteAsync(definition, (step, _) =>
            {
                if (step.Id == "b")
                {
                    throw new InvalidOperationException("simulated process loss");
                }

                return Task.FromResult(HeadlessRunStepResult.Ok());
            }));

            var recovered = await service.RecoverAsync();
            Assert.Single(recovered);
            Assert.Equal(new[] { "a" }, recovered[0].CompletedStepIds);

            var resumed = new System.Collections.Generic.List<string>();
            HeadlessRunResult result = await service.ResumeAsync(definition, (step, _) =>
            {
                resumed.Add(step.Id);
                return Task.FromResult(HeadlessRunStepResult.Ok());
            });
            Assert.Equal(HeadlessRunState.Succeeded, result.State);
            Assert.Equal(new[] { "b" }, resumed);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ExecuteAsync_FailsClosedOnDependencyCycle()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-run-{Guid.NewGuid():N}.jsonl");
        try
        {
            var service = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var definition = new HeadlessRunDefinition("run-3", new[]
            {
                new HeadlessRunStep("a", "work", "a", new[] { "b" }),
                new HeadlessRunStep("b", "work", "b", new[] { "a" }),
            });
            HeadlessRunResult result = await service.ExecuteAsync(
                definition,
                (_, _) => Task.FromResult(HeadlessRunStepResult.Ok()));
            Assert.Equal(HeadlessRunState.Failed, result.State);
            Assert.Equal("mission_dependency_cycle_or_missing_dependency", result.Error);
            Assert.Empty(result.CompletedStepIds);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task JsonJournal_RejectsCorruptLines()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-run-{Guid.NewGuid():N}.jsonl");
        try
        {
            await File.WriteAllTextAsync(path, "not-json\n");
            var journal = new JsonLinesHeadlessRunJournal(path);
            await Assert.ThrowsAsync<InvalidDataException>(() => journal.ReadAllAsync());
        }
        finally
        {
            File.Delete(path);
        }
    }
}
