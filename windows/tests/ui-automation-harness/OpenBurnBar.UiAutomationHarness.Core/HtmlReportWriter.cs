using System;
using System.IO;
using System.Net;
using System.Text;

namespace OpenBurnBar.UiAutomationHarness.Core;

public static class HtmlReportWriter
{
    public static void Write(string path, UiHarnessRunSummary summary, ArtifactRedactor redactor)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var html = new StringBuilder();
        html.AppendLine("<!doctype html>");
        html.AppendLine("<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
        html.AppendLine("<title>OpenBurnBar Windows UI Automation</title>");
        html.AppendLine("<style>body{font:14px/1.45 Segoe UI,system-ui,sans-serif;margin:32px;color:#f4f0ea;background:#161412}h1{font-size:24px}table{border-collapse:collapse;width:100%;margin:18px 0}th,td{border-bottom:1px solid #3a332d;padding:8px;text-align:left;vertical-align:top}.pass{color:#8ee59f}.fail{color:#ff9288}.muted{color:#b9aea4}code{color:#ffd58a}.thumb{max-width:240px;border:1px solid #3a332d}</style>");
        html.AppendLine("</head><body>");
        html.AppendLine($"<h1>OpenBurnBar Windows UI Automation: <span class=\"{Css(summary.Verdict)}\">{summary.Verdict}</span></h1>");
        html.AppendLine($"<p class=\"muted\">Generated {Esc(summary.GeneratedAtUtc)} from <code>{Esc(redactor.Redact(summary.AppExe))}</code></p>");
        html.AppendLine("<h2>Routes</h2><table><thead><tr><th>Route</th><th>Verdict</th><th>Anchor</th><th>Size</th><th>Luma StdDev</th><th>Evidence</th><th>Message</th></tr></thead><tbody>");
        foreach (RouteSmokeEvidence route in summary.Routes)
        {
            html.Append("<tr>");
            html.Append($"<td><code>{Esc(route.RouteKey)}</code></td>");
            html.Append($"<td class=\"{Css(route.Verdict)}\">{route.Verdict}</td>");
            html.Append($"<td><code>{Esc(route.ExpectedAutomationId)}</code> {route.ExpectedAutomationIdFound}</td>");
            html.Append($"<td>{route.Width:0} x {route.Height:0}</td>");
            html.Append($"<td>{route.LumaStdDev:0.##}</td>");
            html.Append("<td>");
            if (!string.IsNullOrWhiteSpace(route.ScreenshotPath))
            {
                html.Append($"<a href=\"{Esc(Rel(path, route.ScreenshotPath))}\">screenshot</a>");
            }
            html.Append("</td>");
            html.Append($"<td>{Esc(redactor.Redact(route.Message))}</td>");
            html.AppendLine("</tr>");
        }

        html.AppendLine("</tbody></table>");
        if (summary.SemanticProbe is { } probe)
        {
            html.AppendLine("<h2>Semantic Probe</h2><table><tbody>");
            html.AppendLine($"<tr><th>Verdict</th><td class=\"{Css(probe.Verdict)}\">{probe.Verdict}</td></tr>");
            html.AppendLine($"<tr><th>Window</th><td>{Esc(probe.WindowTitle)} / {Esc(probe.ProcessImageName)}</td></tr>");
            html.AppendLine($"<tr><th>Deny flags</th><td>password={probe.IsPasswordField}, secureDesktop={probe.IsSecureDesktop}, credentialPrompt={probe.IsCredentialPrompt}</td></tr>");
            html.AppendLine($"<tr><th>Message</th><td>{Esc(redactor.Redact(probe.Message))}</td></tr>");
            if (!string.IsNullOrWhiteSpace(probe.ScreenshotPath))
            {
                html.AppendLine($"<tr><th>Capture</th><td><a href=\"{Esc(Rel(path, probe.ScreenshotPath))}\">external window screenshot</a></td></tr>");
            }

            html.AppendLine("</tbody></table>");
        }

        html.AppendLine("<h2>Input Route Contract</h2><table><thead><tr><th>Action</th><th>Verdict</th><th>Route</th><th>Audit Kind</th><th>Token Required</th><th>Message</th></tr></thead><tbody>");
        foreach (InputRouteEvidence input in summary.InputRoutes)
        {
            html.AppendLine($"<tr><td>{Esc(input.ActionKind)}</td><td class=\"{Css(input.Verdict)}\">{input.Verdict}</td><td>{Esc(input.DispatchRoute)}</td><td><code>{Esc(input.AuditKind)}</code></td><td>{input.RequiresCapabilityToken}</td><td>{Esc(redactor.Redact(input.Message))}</td></tr>");
        }

        html.AppendLine("</tbody></table>");
        html.AppendLine("</body></html>");
        File.WriteAllText(path, html.ToString());
    }

    private static string Css(HarnessVerdict verdict) => verdict == HarnessVerdict.Pass ? "pass" : "fail";

    private static string Esc(string? value) => WebUtility.HtmlEncode(value ?? string.Empty);

    private static string Rel(string reportPath, string artifactPath)
    {
        try
        {
            var reportDir = Path.GetDirectoryName(Path.GetFullPath(reportPath))!;
            return Path.GetRelativePath(reportDir, artifactPath).Replace('\\', '/');
        }
        catch (ArgumentException)
        {
            return artifactPath;
        }
    }
}
