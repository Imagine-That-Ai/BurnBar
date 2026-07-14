using System.Linq;
using OpenBurnBar.App.Settings.ViewModels.Daemon;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

/// <summary>
/// Locks the Engine Room tab's substitution matrix to WPD-0006 plus workstreams
/// promoted by WPD-0009. If either decision changes, these assertions move with it.
/// </summary>
public sealed class DaemonSubstitutionMatrixTests
{
    [Fact]
    public void Matrix_HasAllThirtyFourRows_InOrder()
    {
        Assert.Equal(34, DaemonSubstitutionMatrix.Rows.Count);
        Assert.Equal(DaemonSubstitutionMatrix.TotalCount, DaemonSubstitutionMatrix.Rows.Count);

        // Numbers are 1..34 in order.
        var numbers = DaemonSubstitutionMatrix.Rows.Select(r => r.Number).ToArray();
        Assert.Equal(Enumerable.Range(1, 34).ToArray(), numbers);
    }

    [Fact]
    public void PrimaryDispositionCounts_MatchTheCurrentDecisionSummary()
    {
        Assert.Equal(24, DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstitutedAlready));
        Assert.Equal(3, DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstituteToBuild));
        Assert.Equal(3, DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.Deferred));
        Assert.Equal(4, DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.NotApplicable));

        // Published constants agree with the live count.
        Assert.Equal(DaemonSubstitutionMatrix.SubstitutedAlreadyCount,
            DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstitutedAlready));
        Assert.Equal(DaemonSubstitutionMatrix.SubstituteToBuildCount,
            DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstituteToBuild));
        Assert.Equal(DaemonSubstitutionMatrix.DeferredCount,
            DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.Deferred));
        Assert.Equal(DaemonSubstitutionMatrix.NotApplicableCount,
            DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.NotApplicable));
    }

    [Fact]
    public void CountsSumToTotal()
    {
        int sum = DaemonSubstitutionMatrix.SubstitutedAlreadyCount
                  + DaemonSubstitutionMatrix.SubstituteToBuildCount
                  + DaemonSubstitutionMatrix.DeferredCount
                  + DaemonSubstitutionMatrix.NotApplicableCount;
        Assert.Equal(DaemonSubstitutionMatrix.TotalCount, sum);
    }

    [Theory]
    // WPD-0006 dispositions after the accepted WPD-0009 promotions.
    [InlineData(1, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(2, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(3, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(4, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(5, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(6, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(7, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(8, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(9, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(11, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(12, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(13, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(14, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(15, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(16, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(19, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(20, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(21, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(22, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(23, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(24, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(25, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(27, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(29, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(26, DaemonSubstitutionDisposition.SubstituteToBuild)]
    [InlineData(30, DaemonSubstitutionDisposition.SubstituteToBuild)]
    [InlineData(31, DaemonSubstitutionDisposition.SubstituteToBuild)]
    [InlineData(10, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(17, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(28, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(34, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(32, DaemonSubstitutionDisposition.Deferred)]
    public void Row_HasExpectedDisposition(int number, DaemonSubstitutionDisposition expected)
    {
        var row = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == number);
        Assert.Equal(expected, row.Disposition);
    }

    [Fact]
    public void DeferredRows_ExcludePromotedWpd0009Workstreams()
    {
        var deferred = DaemonSubstitutionMatrix.RowsWith(DaemonSubstitutionDisposition.Deferred)
            .Select(r => r.Number)
            .OrderBy(n => n)
            .ToArray();
        Assert.Equal(new[] { 18, 32, 33 }, deferred);
    }

    [Fact]
    public void HybridRows_CarryASubBuildRemainder()
    {
        // Rows 24 and 27 are SUB-DONE (core/protocol) with a named SUB-BUILD remainder.
        foreach (var number in new[] { 24, 27 })
        {
            var row = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == number);
            Assert.Equal(DaemonSubstitutionDisposition.SubstitutedAlready, row.Disposition);
            Assert.Equal(DaemonSubstitutionDisposition.SubstituteToBuild, row.RemainderDisposition);
            Assert.Contains("/ SUB-BUILD", row.DispositionBadge);
        }
    }

    [Fact]
    public void DispositionCodes_RenderExactWpd0006Tokens()
    {
        Assert.Equal("SUB-DONE", DaemonSubstitutionDispositionMetadata.Code(DaemonSubstitutionDisposition.SubstitutedAlready));
        Assert.Equal("SUB-BUILD", DaemonSubstitutionDispositionMetadata.Code(DaemonSubstitutionDisposition.SubstituteToBuild));
        Assert.Equal("DEFER", DaemonSubstitutionDispositionMetadata.Code(DaemonSubstitutionDisposition.Deferred));
        Assert.Equal("N/A", DaemonSubstitutionDispositionMetadata.Code(DaemonSubstitutionDisposition.NotApplicable));
    }

    [Fact]
    public void QualifiedRows_RenderTheParentheticalScopeNote()
    {
        // Row 11 is "SUB-DONE (transport primitive)".
        var row11 = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == 11);
        Assert.Equal("transport primitive", row11.Qualifier);
        Assert.Equal("SUB-DONE (transport primitive)", row11.DispositionBadge);

        // Row 6 is "SUB-DONE (production scorecard)".
        var row6 = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == 6);
        Assert.Equal("production scorecard", row6.Qualifier);
        Assert.Equal("SUB-DONE (production scorecard)", row6.DispositionBadge);

        // Row 29 is "SUB-DONE (authenticated standalone client)".
        var row29 = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == 29);
        Assert.Equal("authenticated standalone client", row29.Qualifier);
        Assert.Equal("SUB-DONE (authenticated standalone client)", row29.DispositionBadge);

        // Row 19 is "SUB-DONE (durable source-free semantic store)".
        var row19 = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == 19);
        Assert.Equal("durable source-free semantic store", row19.Qualifier);
        Assert.Equal("SUB-DONE (durable source-free semantic store)", row19.DispositionBadge);

        // Row 22 is "SUB-DONE (per-client token bucket)".
        var row22 = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == 22);
        Assert.Equal("per-client token bucket", row22.Qualifier);
        Assert.Equal("SUB-DONE (per-client token bucket)", row22.DispositionBadge);

        // Row 16 is "SUB-DONE (protected live command bridge)".
        var row16 = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == 16);
        Assert.Equal("protected live command bridge", row16.Qualifier);
        Assert.Equal("SUB-DONE (protected live command bridge)", row16.DispositionBadge);
    }

    [Fact]
    public void OnlySubDoneRows_AreLiveOnV1()
    {
        foreach (var row in DaemonSubstitutionMatrix.Rows)
        {
            Assert.Equal(row.Disposition == DaemonSubstitutionDisposition.SubstitutedAlready, row.IsLiveOnV1);
        }
    }

    [Fact]
    public void EveryRow_HasCapabilityRationaleAndTracking()
    {
        Assert.All(DaemonSubstitutionMatrix.Rows, row =>
        {
            Assert.False(string.IsNullOrWhiteSpace(row.Capability));
            Assert.False(string.IsNullOrWhiteSpace(row.Rationale));
            Assert.False(string.IsNullOrWhiteSpace(row.Tracking));
        });
    }
}
