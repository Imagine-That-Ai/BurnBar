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
        Assert.Equal(11, DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstitutedAlready));
        Assert.Equal(3, DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstituteToBuild));
        Assert.Equal(16, DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.Deferred));
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
    // WPD-0006 dispositions plus the WPD-0009 row 25 promotion.
    [InlineData(5, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(9, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(11, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(12, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(13, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(14, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(15, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(23, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(24, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(25, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(27, DaemonSubstitutionDisposition.SubstitutedAlready)]
    [InlineData(26, DaemonSubstitutionDisposition.SubstituteToBuild)]
    [InlineData(30, DaemonSubstitutionDisposition.SubstituteToBuild)]
    [InlineData(31, DaemonSubstitutionDisposition.SubstituteToBuild)]
    [InlineData(10, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(17, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(28, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(34, DaemonSubstitutionDisposition.NotApplicable)]
    [InlineData(1, DaemonSubstitutionDisposition.Deferred)]
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
        Assert.Equal(new[] { 1, 2, 3, 4, 6, 7, 8, 16, 18, 19, 20, 21, 22, 29, 32, 33 }, deferred);
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

        // Row 6 is a SWIFT-REUSE-on-revive DEFER.
        var row6 = DaemonSubstitutionMatrix.Rows.Single(r => r.Number == 6);
        Assert.Equal("SWIFT-REUSE on revive", row6.Qualifier);
        Assert.Equal("DEFER (SWIFT-REUSE on revive)", row6.DispositionBadge);
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
