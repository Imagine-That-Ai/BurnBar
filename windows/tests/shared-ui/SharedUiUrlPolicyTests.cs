using Xunit;

namespace OpenBurnBar.App.SharedUi.Tests;

/// <summary>
/// The Stripe + update URL allowlists — mirrors of the Linux validators
/// (lib.rs validate_external_url, update_feed.rs validate_update_artifact_url)
/// with the pinned error-string taxonomy.
/// </summary>
public sealed class SharedUiUrlPolicyTests
{
    [Theory]
    [InlineData("https://checkout.stripe.com/c/pay_abc")]
    [InlineData("https://billing.stripe.com/p/session/test_123")]
    [InlineData("https://buy.stripe.com/7sK28j0")]
    public void ExternalUrlAllowsStripeHosts(string url)
    {
        Assert.StartsWith("https://", SharedUiUrlPolicy.ValidateExternalUrl(url));
    }

    [Theory]
    [InlineData("http://checkout.stripe.com/c/pay", "external_url_origin_refused")]
    [InlineData("https://checkout.stripe.com:8443/c/pay", "external_url_origin_refused")]
    [InlineData("https://user@checkout.stripe.com/c/pay", "external_url_origin_refused")]
    [InlineData("https://stripe.com/c/pay", "external_url_host_refused")]
    [InlineData("https://checkout.stripe.com.evil.com/c/pay", "external_url_host_refused")]
    [InlineData("https://burnbar.ai/downloads/x", "external_url_host_refused")]
    [InlineData("not-a-url", "external_url_invalid")]
    public void ExternalUrlRefusesOutsideTheAllowlist(string url, string expectedError)
    {
        var ex = Assert.Throws<SharedUiCommandException>(() => SharedUiUrlPolicy.ValidateExternalUrl(url));
        Assert.Equal(expectedError, ex.Message);
    }

    [Fact]
    public void ExternalUrlRefusesOverlongUrls()
    {
        var url = "https://checkout.stripe.com/" + new string('a', 3000);
        var ex = Assert.Throws<SharedUiCommandException>(() => SharedUiUrlPolicy.ValidateExternalUrl(url));
        Assert.Equal("external_url_too_long", ex.Message);
    }

    [Theory]
    [InlineData("https://burnbar.ai/downloads/openburnbar/linux.AppImage")]
    [InlineData("https://www.burnbar.ai/downloads/openburnbar/linux.AppImage")]
    [InlineData("https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.0.0/app.msix")]
    public void UpdateUrlAllowsSignedChannels(string url)
    {
        Assert.StartsWith("https://", SharedUiUrlPolicy.ValidateUpdateUrl(url));
    }

    [Theory]
    [InlineData("http://burnbar.ai/downloads/x", "update_url_origin_refused")]
    [InlineData("https://burnbar.ai/downloads/x?sig=1", "update_url_origin_refused")]
    [InlineData("https://burnbar.ai/downloads/x#frag", "update_url_origin_refused")]
    [InlineData("https://user@burnbar.ai/downloads/x", "update_url_origin_refused")]
    [InlineData("https://downloads.burnbar.ai/x", "update_url_path_refused")]
    [InlineData("https://burnbar.ai/other/x", "update_url_path_refused")]
    [InlineData("https://github.com/Other/Repo/releases/download/v1/x", "update_url_path_refused")]
    [InlineData("https://objects.githubusercontent.com/x", "update_url_path_refused")]
    [InlineData("https://evil.com/downloads/x", "update_url_origin_refused")]
    [InlineData("not-a-url", "update_url_invalid")]
    public void UpdateUrlRefusesOutsideTheAllowlist(string url, string expectedError)
    {
        var ex = Assert.Throws<SharedUiCommandException>(() => SharedUiUrlPolicy.ValidateUpdateUrl(url));
        Assert.Equal(expectedError, ex.Message);
    }
}
