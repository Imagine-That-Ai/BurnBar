using System;
using System.IO;
using System.Security;
using System.Text;

namespace OpenBurnBar.UiAutomationHarness.Core;

public static class JUnitReportWriter
{
    public static void Write(string path, UiHarnessRunSummary summary, ArtifactRedactor redactor)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tests = summary.Routes.Count + (summary.SemanticProbe is null ? 0 : 1) + summary.InputRoutes.Count;
        var failures = 0;
        foreach (RouteSmokeEvidence route in summary.Routes)
        {
            if (route.Verdict == HarnessVerdict.Fail)
            {
                failures++;
            }
        }

        if (summary.SemanticProbe?.Verdict == HarnessVerdict.Fail)
        {
            failures++;
        }

        var xml = new StringBuilder();
        xml.AppendLine($"""<?xml version="1.0" encoding="utf-8"?>""");
        xml.AppendLine($"""<testsuite name="OpenBurnBar.Windows.UiAutomation" tests="{tests}" failures="{failures}" skipped="0">""");
        foreach (RouteSmokeEvidence route in summary.Routes)
        {
            WriteCase(xml, $"route.{route.RouteKey}", route.Verdict, route.ElapsedMs / 1000d, route.Message, redactor);
        }

        if (summary.SemanticProbe is { } probe)
        {
            WriteCase(xml, "semantic.frontmost-window", probe.Verdict, 0, probe.Message, redactor);
        }

        foreach (InputRouteEvidence input in summary.InputRoutes)
        {
            WriteCase(xml, $"input-route.{input.ActionKind}", HarnessVerdict.Pass, 0, $"{input.DispatchRoute} {input.AuditKind}", redactor);
        }

        xml.AppendLine("</testsuite>");
        File.WriteAllText(path, xml.ToString());
    }

    private static void WriteCase(
        StringBuilder xml,
        string name,
        HarnessVerdict verdict,
        double seconds,
        string? message,
        ArtifactRedactor redactor)
    {
        xml.Append($"""  <testcase classname="OpenBurnBar.Windows.UiAutomation" name="{Escape(name)}" time="{seconds:0.###}">""");
        if (verdict == HarnessVerdict.Fail)
        {
            xml.AppendLine();
            xml.AppendLine($"""    <failure message="{Escape(redactor.Redact(message))}" />""");
            xml.AppendLine("  </testcase>");
            return;
        }

        xml.AppendLine("</testcase>");
    }

    private static string Escape(string? value) => SecurityElement.Escape(value ?? string.Empty) ?? string.Empty;
}
