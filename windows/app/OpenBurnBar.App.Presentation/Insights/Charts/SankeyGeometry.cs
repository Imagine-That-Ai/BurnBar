using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure layout for the compact two-column sankey — a direct port of the macOS
/// <c>InsightSankeyView.orderedColumns</c> plus the node-height math.
///
/// Links are grouped into a source column (summing each source's outbound weight) and a target
/// column (summing each target's inbound weight); nodes in each column are ordered by
/// descending weight, and each node's height is <c>max(8, (weight/columnTotal)·H·0.92)</c>.
/// The unit tests assert the column ordering and the normalized heights for a known link set.
/// </summary>
public static class SankeyGeometry
{
    private const double NodeWidth = 12;
    private const double NodeGap = 2;
    private const double HeightFraction = 0.92;
    private const double MinNodeHeight = 8;

    /// <summary>Group + order the source and target columns for a link set.</summary>
    public static SankeyGeometryResult OrderColumns(SankeyData data, PlotRect rect)
    {
        Dictionary<string, SankeyNode> lookup = data.Nodes
            .GroupBy(n => n.Id)
            .ToDictionary(g => g.Key, g => g.First());

        List<(string Id, double Weight)> sources = data.Links
            .GroupBy(l => l.Source)
            .Select(g => (g.Key, g.Sum(l => l.Value)))
            .OrderByDescending(x => x.Item2)
            .ThenBy(x => x.Key, StringComparer.Ordinal)
            .ToList();

        List<(string Id, double Weight)> targets = data.Links
            .GroupBy(l => l.Target)
            .Select(g => (g.Key, g.Sum(l => l.Value)))
            .OrderByDescending(x => x.Item2)
            .ThenBy(x => x.Key, StringComparer.Ordinal)
            .ToList();

        double leftX = rect.X;
        double rightX = rect.Right - NodeWidth;

        SankeyColumn left = BuildColumn("source", sources, lookup, rect, leftX);
        SankeyColumn right = BuildColumn("target", targets, lookup, rect, rightX);
        return new SankeyGeometryResult(new List<SankeyColumn> { left, right });
    }

    private static SankeyColumn BuildColumn(
        string id,
        List<(string Id, double Weight)> entries,
        IReadOnlyDictionary<string, SankeyNode> lookup,
        PlotRect rect,
        double columnX)
    {
        double total = entries.Sum(e => e.Weight);
        double denom = total > 0 ? total : 1;

        var nodes = new List<SankeyColumnNode>(entries.Count);
        double y = rect.Y;
        foreach ((string nodeId, double weight) in entries)
        {
            double normalized = weight / denom;
            double height = Math.Max(MinNodeHeight, normalized * rect.Height * HeightFraction);
            lookup.TryGetValue(nodeId, out SankeyNode? node);
            string label = node?.Label ?? nodeId;
            InsightRgb color = InsightFormatting.ResolveColor(node?.ColorHex, nodeId);
            nodes.Add(new SankeyColumnNode(nodeId, label, weight, normalized, columnX, y, NodeWidth, height, color));
            y += height + NodeGap;
        }

        return new SankeyColumn(id, total, nodes);
    }
}
