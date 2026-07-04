namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// Static page assets the bridge serves.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgePage.swift (html / brandLogoSVG).
//
// The full dashboard HTML/SVG lives in a separate presentation asset lane
// (SmartHubBridgePage.swift, out of this integration lane's 8-file scope). The
// bridge ROUTE DISPATCH only needs these as opaque strings — GET /render.html
// returns Html, GET /brand-logo.svg returns BrandLogoSvg — so they are
// injectable here. The Windows app binds the real dashboard document; this
// default keeps the router self-contained and testable.

public sealed record BridgeAssets(string Html, string BrandLogoSvg)
{
    public static BridgeAssets Placeholder { get; } = new(
        Html: "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenBurnBar Smart Display</title></head><body></body></html>",
        BrandLogoSvg: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"></svg>");
}
