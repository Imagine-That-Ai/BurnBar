using System;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// URL allowlists for open_external_url / open_update_url — a byte-level mirror
/// of the Linux validators (apps/linux-desktop/src-tauri/src/lib.rs
/// validate_external_url + update_feed.rs validate_update_artifact_url),
/// including the exact error-string taxonomy the frontend/tests pin.
///
/// open_external_url: https only, no userinfo, port 443 only, host in
/// {checkout,billing,buy}.stripe.com (the membership checkout flow).
/// open_update_url: https only, no userinfo/query/fragment, host in
/// {burnbar.ai, www.burnbar.ai, downloads.burnbar.ai} with /downloads/* path,
/// or github.com with /Imagine-That-Ai/BurnBar/releases/download/* path
/// (the two *usercontent.com hosts are allowed by the feed signer but carry no
/// path rule on Linux — mirrored here for parity, they fail the path check).
/// </summary>
public static class SharedUiUrlPolicy
{
    private const int MaxUrlLength = 2048;

    /// <summary>Validate a Stripe-hosted external URL; returns the normalized URL.</summary>
    public static string ValidateExternalUrl(string rawUrl)
    {
        if (rawUrl.Length > MaxUrlLength)
        {
            throw new SharedUiCommandException("external_url_too_long");
        }

        if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var url))
        {
            throw new SharedUiCommandException("external_url_invalid");
        }

        // https + no userinfo + port 443 only (Uri.Port is 443 for the implicit
        // default https port, so this one check covers both forms).
        if (!string.Equals(url.Scheme, "https", StringComparison.Ordinal)
            || !string.IsNullOrEmpty(url.UserInfo)
            || url.Port != 443)
        {
            throw new SharedUiCommandException("external_url_origin_refused");
        }

        var host = url.Host;
        var allowed = string.Equals(host, "checkout.stripe.com", StringComparison.OrdinalIgnoreCase)
                      || string.Equals(host, "billing.stripe.com", StringComparison.OrdinalIgnoreCase)
                      || string.Equals(host, "buy.stripe.com", StringComparison.OrdinalIgnoreCase);
        if (!allowed)
        {
            throw new SharedUiCommandException("external_url_host_refused");
        }

        return url.AbsoluteUri;
    }

    /// <summary>Validate an update-download URL; returns the normalized URL.</summary>
    public static string ValidateUpdateUrl(string rawUrl)
    {
        if (rawUrl.Length > MaxUrlLength)
        {
            throw new SharedUiCommandException("update_url_too_long");
        }

        if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var url))
        {
            throw new SharedUiCommandException("update_url_invalid");
        }

        if (!IsAllowedDownloadUrl(url) || !string.IsNullOrEmpty(url.Query) || !string.IsNullOrEmpty(url.Fragment))
        {
            throw new SharedUiCommandException("update_url_origin_refused");
        }

        var host = url.Host;
        var pathOk = host.Equals("burnbar.ai", StringComparison.OrdinalIgnoreCase)
                     || host.Equals("www.burnbar.ai", StringComparison.OrdinalIgnoreCase)
                         ? url.AbsolutePath.StartsWith("/downloads/", StringComparison.Ordinal)
                     : host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
                         ? url.AbsolutePath.StartsWith(
                             "/Imagine-That-Ai/BurnBar/releases/download/", StringComparison.Ordinal)
                         : false;
        if (!pathOk)
        {
            throw new SharedUiCommandException("update_url_path_refused");
        }

        return url.AbsoluteUri;
    }

    private static bool IsAllowedDownloadUrl(Uri url)
    {
        if (!string.Equals(url.Scheme, "https", StringComparison.Ordinal) || !string.IsNullOrEmpty(url.UserInfo))
        {
            return false;
        }

        var host = url.Host;
        return host.Equals("burnbar.ai", StringComparison.OrdinalIgnoreCase)
               || host.Equals("www.burnbar.ai", StringComparison.OrdinalIgnoreCase)
               || host.Equals("downloads.burnbar.ai", StringComparison.OrdinalIgnoreCase)
               || host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
               || host.Equals("objects.githubusercontent.com", StringComparison.OrdinalIgnoreCase)
               || host.Equals("github-releases.githubusercontent.com", StringComparison.OrdinalIgnoreCase);
    }
}
