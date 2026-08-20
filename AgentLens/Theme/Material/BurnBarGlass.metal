//  BurnBarGlass.metal
//
//  BurnBar's material is a *volume*, not a panel.
//
//  Why a shader at all: the app deploys macOS 14 / iOS 17 and every Liquid Glass API
//  is macOS 26. `Shader`, `ShaderLibrary` and `layerEffect` land at exactly that floor
//  (SwiftUICore.swiftinterface:8197/8167/8282), so hand-authored optics are the only
//  way to give the whole install base real material. Native `glassEffect` is a
//  substitution on 26+, not the baseline.
//
//  The physical model, and why each term is here rather than "blur plus a white border":
//
//  1. HEIGHT FIELD. The plate is a spherical cap — thick in the middle, falling to zero
//     at the rim. Everything else derives from it. Without a height field there is no
//     thickness, and without thickness glass is just tinted paper.
//  2. 3D NORMAL. From the gradient of that height, as a real float3. A 2D edge gradient
//     can only push pixels sideways; a 3D normal is what lets light have an angle of
//     incidence, which is what specular and Fresnel need to mean anything.
//  3. REFRACTION with PER-CHANNEL IOR. Snell's law via `refract()`, run three times at
//     slightly different indices. Red bends least, blue most. That spectral separation
//     is the single most convincing cue that a surface is glass and not plastic.
//  4. MAGNIFICATION. A convex lens enlarges what is behind it. Sampling is scaled from
//     the plate centre proportionally to thickness, so the middle genuinely magnifies.
//  5. FRESNEL. Reflectance rises at grazing angles (Schlick). This is why real glass is
//     transparent face-on and mirror-bright at the rim — and why a uniform-opacity
//     "glass" panel never looks right.
//  6. CAUSTICS. Where the surface curvature converges rays, light concentrates. Driven
//     by the Laplacian of the height field, so bright filaments appear exactly where a
//     real lens would focus them.
//  7. SUBSURFACE SCATTER. Light entering the body bleeds sideways before exiting,
//     tinted by what it passed through. This is what gives jewels their inner glow.
//  8. INTERNAL REFLECTION. A faint inverted image of the opposite rim, reflected off the
//     inside of the back face.
//
//  Sampling budget: 3 refraction taps + 4 scatter taps + 1 reflection tap = 8 per pixel.
//  Bounded and constant — no loops over primitive counts.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Geometry

/// Signed distance to a rounded rectangle. Negative inside.
static float sdRoundedBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

/// Thickness of the glass at a point, as a spherical cap over the bevel band.
///
/// `sqrt(1 - (1-t)^2)` is the circle equation — it gives a genuinely spherical
/// shoulder rather than the linear ramp a smoothstep would produce. The difference is
/// visible: a linear bevel reads as a chamfered plastic edge, a spherical one reads as
/// a lens.
static float glassHeight(float dist, float band, float domeRadius, float dome) {
    // The bevelled slab: curves over `band`, then a flat plateau.
    float bevel  = clamp(-dist / max(band, 0.001), 0.0, 1.0);
    float bevelI = 1.0 - bevel;
    float bevelH = sqrt(max(0.0, 1.0 - bevelI * bevelI));

    // The full dome: curves across the ENTIRE plate, so every pixel has a normal that
    // is tilted and therefore refracts. This is the term that was missing — a plateau
    // has a normal of (0,0,1), which refracts nothing, so the old height field could
    // only ever bend a thin rim and the middle of every plate was optically inert.
    float d  = clamp(-dist / max(domeRadius, 0.001), 0.0, 1.0);
    float dI = 1.0 - d;
    float domeH = sqrt(max(0.0, 1.0 - dI * dI));

    return mix(bevelH, domeH, clamp(dome, 0.0, 1.0));
}

/// Surface normal in 3D, from the gradient of the height field.
static float3 glassNormal(float2 p, float2 halfSize, float radius, float band, float relief,
                          float domeRadius, float dome) {
    const float e = 1.0;
    float hx1 = glassHeight(sdRoundedBox(p + float2(e, 0.0), halfSize, radius), band, domeRadius, dome);
    float hx0 = glassHeight(sdRoundedBox(p - float2(e, 0.0), halfSize, radius), band, domeRadius, dome);
    float hy1 = glassHeight(sdRoundedBox(p + float2(0.0, e), halfSize, radius), band, domeRadius, dome);
    float hy0 = glassHeight(sdRoundedBox(p - float2(0.0, e), halfSize, radius), band, domeRadius, dome);
    // `relief` scales how pronounced the dome is; higher = a fatter, more domed jewel.
    float2 grad = float2(hx1 - hx0, hy1 - hy0) * relief;
    return normalize(float3(-grad, 1.0));
}

/// Laplacian of the height field — curvature. Positive where the surface converges,
/// which is exactly where a lens focuses light into a caustic.
static float glassCurvature(float2 p, float2 halfSize, float radius, float band,
                            float domeRadius, float dome) {
    const float e = 1.5;
    float h  = glassHeight(sdRoundedBox(p, halfSize, radius), band, domeRadius, dome);
    float hx1 = glassHeight(sdRoundedBox(p + float2(e, 0.0), halfSize, radius), band, domeRadius, dome);
    float hx0 = glassHeight(sdRoundedBox(p - float2(e, 0.0), halfSize, radius), band, domeRadius, dome);
    float hy1 = glassHeight(sdRoundedBox(p + float2(0.0, e), halfSize, radius), band, domeRadius, dome);
    float hy0 = glassHeight(sdRoundedBox(p - float2(0.0, e), halfSize, radius), band, domeRadius, dome);
    return (hx1 + hx0 + hy1 + hy0 - 4.0 * h);
}

/// Hold a sample inside the declared budget.
///
/// Returns `tap` when it is already within `budget` of `origin`, and otherwise the
/// point on that ray at exactly `budget`. Shortening a ray keeps the direction — and
/// therefore the character of the refraction — while an out-of-budget read would be
/// silently snapped to the layer edge.
static float2 burnBarClampTap(float2 tap, float2 origin, float budget) {
    float2 delta = tap - origin;
    float  len   = length(delta);
    if (len <= budget || len < 1e-5) { return tap; }
    return origin + delta * (budget / len);
}

/// Schlick's approximation of Fresnel reflectance.
static float fresnel(float cosTheta, float f0) {
    float m = clamp(1.0 - cosTheta, 0.0, 1.0);
    float m2 = m * m;
    return f0 + (1.0 - f0) * (m2 * m2 * m);
}

// MARK: - The lens

/// A physically-motivated glass volume.
///
/// - `size`        layer size in points
/// - `radius`      corner radius
/// - `lensing`     0…1 refraction strength (index of refraction scale)
/// - `dispersion`  0…1 spectral separation between R and B
/// - `specular`    0…1 highlight amplitude
/// - `thickness`   0…1 how deep the volume reads (bevel band + dome relief)
/// - `scatter`     0…1 subsurface bleed
/// - `light`       light position in layer coordinates (tracks the cursor)
/// - `energy`      0…1 ambient energy; brightens caustics when the system is busy
[[ stitchable ]] half4 burnBarGlassLens(float2 position,
                                        SwiftUI::Layer layer,
                                        float2 size,
                                        float radius,
                                        float lensing,
                                        float dispersion,
                                        float specular,
                                        float thickness,
                                        float scatter,
                                        float2 light,
                                        float energy,
                                        float maxTap) {
    float2 halfSize = size * 0.5;
    float2 centred  = position - halfSize;
    float r         = min(radius, min(halfSize.x, halfSize.y));
    float dist      = sdRoundedBox(centred, halfSize, r);

    // Outside the body the modifier must contribute nothing, or it would paint a
    // rectangle across its neighbours.
    if (dist > 0.5) { return half4(0.0h); }

    // Every tap below must stay inside the `maxSampleOffset` the Swift side declared.
    // `SwiftUI::Layer::sample` CLAMPS out-of-budget reads rather than failing, so an
    // over-reaching tap does not error — it silently returns an edge pixel, which
    // shows up as a smear along the rim and reads as a cheap blur. `budget` is passed
    // in rather than assumed so the shader and `LensModifier` cannot drift apart.
    float budget = max(maxTap, 1.0);

    // Thicker glass curves over a wider shoulder. This single number is most of what
    // separates Ledger's precision pane from Canvas's dimensional object.
    // Wider and deeper than the first pass. These were tuned against a tier that never
    // executed on a modern Mac, so the values were conservative guesses; with the lens
    // actually running, a narrow band reads as a bevelled sticker rather than a volume.
    float band   = mix(14.0, 52.0, clamp(thickness, 0.0, 1.0));
    float relief = mix(12.0, 44.0, clamp(thickness, 0.0, 1.0));

    // The dome spans the plate's smaller half-dimension, so a 28pt chip and a 400pt
    // card are the same MATERIAL at different sizes rather than the same fixed bevel
    // reading as a fat plastic border on the chip.
    float domeRadius = min(halfSize.x, halfSize.y);
    float dome       = clamp(thickness, 0.0, 1.0);

    float height = glassHeight(dist, band, domeRadius, dome);
    float3 N     = glassNormal(centred, halfSize, r, band, relief, domeRadius, dome);
    const float3 V = float3(0.0, 0.0, 1.0);          // viewer looks straight on

    // --- Refraction ------------------------------------------------------------
    // Per-channel index of refraction. Crown glass is ~1.52; the spread between R and
    // B is what produces the spectral fringe.
    // Denser than crown glass on purpose: BurnBar's plates are meant to read as thick
    // optical blocks, and 1.52 at these sizes is nearly invisible.
    float baseIOR = mix(1.0, 1.78, clamp(lensing, 0.0, 1.0));
    // Dispersion is the single strongest "this is glass" cue, so it gets real amplitude.
    float spread  = dispersion * 0.14;
    float3 iors   = float3(baseIOR - spread, baseIOR, baseIOR + spread);

    // Depth the ray travels through the body before exiting.
    float travel = height * band * 2.10 * lensing;

    // Magnification: a convex lens enlarges what is behind it. Scaling the sample
    // toward the centre in proportion to thickness is the 2D equivalent.
    // Real, visible magnification — a lens that does not enlarge is a window.
    float  magnify = 1.0 - 0.14 * lensing * height;
    float2 magnified = halfSize + centred * magnify;

    float3 refractedRGB;
    for (int i = 0; i < 3; ++i) {
        float3 dir = refract(-V, N, 1.0 / iors[i]);
        // `refract` returns 0 on total internal reflection; fall back to the normal.
        float2 offset = (length(dir) < 1e-4) ? N.xy : dir.xy;
        float2 tap = magnified + offset * travel;
        half4 s = layer.sample(clamp(burnBarClampTap(tap, position, budget), float2(0.0), size));
        refractedRGB[i] = float(i == 0 ? s.r : (i == 1 ? s.g : s.b));
    }
    float alpha = float(layer.sample(clamp(burnBarClampTap(magnified, position, budget), float2(0.0), size)).a);

    // --- Subsurface scatter ----------------------------------------------------
    // Light that entered the body and bled sideways before exiting. Four cheap taps
    // at the scatter radius, averaged — this is the inner glow of a jewel.
    float3 scattered = refractedRGB;
    if (scatter > 0.01) {
        float rad = band * 0.85 * scatter;
        float3 acc = float3(0.0);
        const float2 dirs[4] = { float2(1,0), float2(-1,0), float2(0,1), float2(0,-1) };
        for (int i = 0; i < 4; ++i) {
            half4 s = layer.sample(
                clamp(burnBarClampTap(magnified + dirs[i] * rad, position, budget), float2(0.0), size));
            acc += float3(s.rgb);
        }
        // Scatter is strongest deep in the body, absent at the rim.
        scattered = mix(refractedRGB, acc * 0.25, scatter * height * 0.75);
    }

    // --- Internal reflection ---------------------------------------------------
    // A faint inverted image off the inside of the back face. Subtle, but it is what
    // stops the interior reading as flat tinted glass.
    // Displacement here is `-1.85 * centred`, which scales with the PLATE, not with
    // the sampling budget: on a 400pt card the tap reaches ~370pt from the pixel, four
    // times the old fixed 96pt offset. It was the single biggest silent smear.
    float2 mirrored = burnBarClampTap(halfSize - centred * 0.85, position, budget);
    half4  inner    = layer.sample(clamp(mirrored, float2(0.0), size));
    float  innerAmt = 0.10 * specular * height;
    float3 body     = mix(scattered, float3(inner.rgb), innerAmt);

    // --- Fresnel ---------------------------------------------------------------
    // Reflectance climbs at grazing angles: transparent face-on, bright at the rim.
    float cosTheta = clamp(dot(N, V), 0.0, 1.0);
    // f0 raised from 0.04 (water) toward dense flint, so the rim actually flares.
    float F        = fresnel(cosTheta, 0.09) * specular;

    // --- Specular --------------------------------------------------------------
    // Blinn-Phong from a light that tracks the cursor, so the highlight travels as the
    // pointer moves — the cue that sells a surface as a physical object.
    float3 lightPos = float3(light, max(size.x, size.y) * 0.65);
    float3 L        = normalize(lightPos - float3(position, 0.0));
    float3 H        = normalize(L + V);
    float  spec     = pow(max(dot(N, H), 0.0), 48.0) * specular;

    // A second, wider lobe: the soft sheen across the shoulder.
    float sheen = pow(max(dot(N, H), 0.0), 6.0) * specular * 0.22;

    // --- Caustics --------------------------------------------------------------
    // Curvature focuses light. Positive Laplacian means converging, which is where a
    // real lens throws its bright filament.
    float curvature = glassCurvature(centred, halfSize, r, band, domeRadius, dome);
    float caustic   = max(0.0, curvature) * 44.0 * lensing * (0.45 + energy * 0.55);

    // --- Composite -------------------------------------------------------------
    // Fresnel and caustics tint toward the light rather than pure white; pure white
    // highlights are the tell of a fake material.
    float3 highlight = float3(1.0, 0.985, 0.96);
    float3 lit = body
               + highlight * (spec + sheen)
               + highlight * F * 0.95
               + highlight * caustic;

    // The shadowed shoulder. Real glass has a dark side opposite the light; without it
    // the plate reads as a luminous sticker.
    float away  = clamp(dot(N, -normalize(float3(L.xy, 0.35))), 0.0, 1.0);
    float shade = away * (1.0 - height) * specular * 0.30;
    lit -= float3(shade);

    return half4(half3(clamp(lit, 0.0, 1.0)), half(alpha));
}
